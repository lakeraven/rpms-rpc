# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/practitioner"

# Practitioner.detail(duz) reads NEW PERSON (#200) via DDR GETS ENTRY DATA in
# CIAV VUECENTRIC. Seeds use synthetic fixtures only.
class PractitionerDetailTest < Minitest::Test
  Ddr = RpmsRpc::DdrFileman
  Practitioner = RpmsRpc::Practitioner
  FILEMAN_CONTEXT = Practitioner::FILEMAN_CONTEXT

  DETAIL_FIELDS = "8;29;41.97;41.98;41.99;53.2;53.5;54.2;747.44;8932.1"
  DETAIL_KEYS = %i[
    duz title service_section provider_class person_class
    npi npi_entry_status dea_number dea_state dea_expires
  ].freeze

  class NoWireClient
    class WireReached < StandardError; end

    %i[call_rpc call_rpc_lines call_rpc_global_array].each do |name|
      define_method(name) { |rpc, *| raise WireReached, "#{rpc} reached the wire" }
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def use(client)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
  end

  def gets_key(duz)
    Ddr.gets_entry_param(file: 200, iens: "#{duz},", fields: DETAIL_FIELDS, flags: "IE").to_s
  end

  def seed_detail(mock, duz: 101, authorize_npi: "1", npi: "0000000000", **overrides)
    title = overrides.fetch(:title, "EXAMPLE,PROVIDER")
    service_section = overrides.fetch(:service_section, "EXAMPLE SERVICE")
    provider_class = overrides.fetch(:provider_class, "EXAMPLE PROVIDER CLASS")
    person_class = overrides.fetch(:person_class, "EXAMPLE PERSON CLASS")
    npi_entry_status = overrides.fetch(:npi_entry_status, "ACTIVE")
    dea_number = overrides.fetch(:dea_number, "XX0000000")
    dea_state = overrides.fetch(:dea_state, "EXAMPLE STATE")
    dea_expires_internal = overrides.fetch(:dea_expires_internal, "3291231")
    dea_expires_external = overrides.fetch(:dea_expires_external, "DEC 31, 2029")

    mock.seed(:ddr_gets_entry_data, gets_key(duz), <<~REPLY.chomp)
      [Data]
      200^#{duz},^8^#{title}^#{title}
      200^#{duz},^29^1^#{service_section}
      200^#{duz},^41.97^#{authorize_npi}^#{authorize_npi == '1' ? 'YES' : authorize_npi}
      200^#{duz},^41.98^1^#{npi_entry_status}
      200^#{duz},^41.99^#{npi}^#{npi}
      200^#{duz},^53.2^#{dea_number}^#{dea_number}
      200^#{duz},^53.5^1^#{provider_class}
      200^#{duz},^54.2^99^#{dea_state}
      200^#{duz},^747.44^#{dea_expires_internal}^#{dea_expires_external}
      200^#{duz},^8932.1^1^#{person_class}
    REPLY

    {
      title: title,
      service_section: service_section,
      provider_class: provider_class,
      person_class: person_class,
      npi: authorize_npi == "1" ? npi : nil,
      npi_entry_status: npi_entry_status,
      dea_number: dea_number,
      dea_state: dea_state,
      dea_expires: Date.new(2029, 12, 31),
      authorize_npi: authorize_npi,
      npi_raw: npi
    }
  end

  def assert_logs_no_secrets(secrets)
    out, err = capture_io { yield }
    combined = out + err
    secrets.each { |secret| refute_includes combined, secret.to_s, "logged or printed a field value" }
  end

  def test_detail_maps_each_field_number
    mock = RpmsRpc.mock!
    caller_context = mock.current_context
    fixture = seed_detail(mock)

    result = Practitioner.detail(101)

    expected = {
      duz: 101,
      title: fixture[:title],
      service_section: fixture[:service_section],
      provider_class: fixture[:provider_class],
      person_class: fixture[:person_class],
      npi: fixture[:npi],
      npi_entry_status: fixture[:npi_entry_status],
      dea_number: fixture[:dea_number],
      dea_state: fixture[:dea_state],
      dea_expires: fixture[:dea_expires]
    }
    assert_equal DETAIL_KEYS, result.keys
    assert_equal expected, result

    ddr_calls = mock.received_calls.select { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
    refute_empty ddr_calls
    ddr_calls.each do |call|
      assert_equal FILEMAN_CONTEXT, call[:context],
                   "detail must read FileMan under #{FILEMAN_CONTEXT.inspect}"
    end
    assert_equal [ FILEMAN_CONTEXT, caller_context ], mock.context_binds
  end

  def test_detail_blank_or_nonpositive_id_sends_nothing
    use NoWireClient.new
    [ nil, 0, "-5", "" ].each { |duz| assert_nil Practitioner.detail(duz), duz.inspect }
  end

  def test_detail_empty_fields_are_nil_not_raised_or_invented
    mock = RpmsRpc.mock!
    duz = 101
    mock.seed(:ddr_gets_entry_data, gets_key(duz), <<~REPLY.chomp)
      [Data]
      200^#{duz},^8^^
      200^#{duz},^29^^
      200^#{duz},^41.97^^
      200^#{duz},^41.98^^
      200^#{duz},^41.99^^
      200^#{duz},^53.2^^
      200^#{duz},^53.5^^
      200^#{duz},^54.2^^
      200^#{duz},^747.44^^
      200^#{duz},^8932.1^^
    REPLY

    result = Practitioner.detail(duz)

    assert_equal DETAIL_KEYS, result.keys
    assert_equal({
      duz: 101,
      title: nil,
      service_section: nil,
      provider_class: nil,
      person_class: nil,
      npi: nil,
      npi_entry_status: nil,
      dea_number: nil,
      dea_state: nil,
      dea_expires: nil
    }, result)

    mock.seed(:ddr_gets_entry_data, gets_key(102), "[Data]")
    assert_nil Practitioner.detail(102)
  end

  def test_detail_nil_when_read_errors
    mock = RpmsRpc.mock!
    mock.seed(:ddr_gets_entry_data, gets_key(101), "[ERROR]")
    assert_nil Practitioner.detail(101)
    assert_nil Practitioner.detail(999)
  end

  def test_detail_withholds_npi_unless_release_authorized
    cases = [
      [ "", nil ],
      [ "0", nil ],
      [ "NO", nil ],
      [ "Y", nil ],
      [ "1", "0000000000" ]
    ]
    cases.each do |authorize, expected_npi|
      RpmsRpc.reset!
      seed_detail(RpmsRpc.mock!, duz: 101, authorize_npi: authorize)

      result = Practitioner.detail(101)

      assert_equal expected_npi, result[:npi], "41.97 internal #{authorize.inspect}"
    end
  end

  def test_detail_logs_no_field_values
    fixture = seed_detail(RpmsRpc.mock!)
    secrets = [
      fixture[:title],
      fixture[:service_section],
      fixture[:provider_class],
      fixture[:person_class],
      fixture[:npi_raw],
      fixture[:npi_entry_status],
      fixture[:dea_number],
      fixture[:dea_state]
    ]

    assert_logs_no_secrets(secrets) { Practitioner.detail(101) }
  end
end
