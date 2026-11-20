# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/practitioner"
require_relative "../captured_replies"

# Practitioner.detail(duz) reads NEW PERSON (#200) via DDR GETS ENTRY DATA in
# CIAV VUECENTRIC. The replies are test/fixtures/captured_replies/practitioner-detail.yml
# (spec tools/captured_replies/practitioner-detail.rb), captured from the
# pinned build and replayed through CiaClient's own reply grammar: PROFILE,MD
# (DUZ 206) with the build's synthetic NPI and DEA, PROVIDER,TEST (DUZ 200)
# with every field empty, an NPI with its release left empty (DUZ 207), a
# release with no NPI (DUZ 1), and a DUZ no user has.
class PractitionerDetailTest < Minitest::Test
  SLUG = "practitioner-detail"
  Practitioner = RpmsRpc::Practitioner
  FILEMAN_CONTEXT = Practitioner::FILEMAN_CONTEXT
  CALLER_CONTEXT = "OR CPRS GUI CHART"

  DETAIL_KEYS = %i[
    duz title service_section provider_class
    npi npi_entry_status dea_number dea_expires
  ].freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow)
    client = CapturedReplies::ReplayCiaClient.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {})
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def test_detail_maps_each_field_number
    client = replay("detail_full")
    client.create_context(CALLER_CONTEXT)

    result = Practitioner.detail(206)

    assert_equal DETAIL_KEYS, result.keys
    assert_equal({
      duz: 206,
      title: "PHYSICIAN",
      service_section: "MEDICINE",
      provider_class: "FAMILY PRACTICE",
      npi: "1234567893",
      npi_entry_status: "DONE",
      dea_number: "AP1234563",
      dea_expires: Date.new(2030, 1, 1)
    }, result)
    assert_equal CapturedReplies.flow_calls(SLUG, "detail_full"), sent(client)
    binds = client.calls.select { |c| c[:rpc] == :create_context }.map { |c| c[:params].first }
    assert_equal [ CALLER_CONTEXT, FILEMAN_CONTEXT, CALLER_CONTEXT ], binds,
                 "detail reads FileMan under #{FILEMAN_CONTEXT} and re-binds the caller's option"
    assert_equal "DDR GETS ENTRY DATA", client.calls[2][:rpc], "the read runs between the two binds"
  end

  def test_detail_blank_or_nonpositive_id_sends_nothing
    client = replay(nil)

    [ nil, 0, "-5", "", 4.5, "4.9", "42abc", " 42" ].each { |duz| assert_nil Practitioner.detail(duz), duz.inspect }
    assert_empty client.calls
  end

  # A lost wire: the replay client has no reply to give, so the read raises.
  def test_detail_restores_the_callers_context_when_the_read_raises
    client = replay(nil)
    client.create_context(CALLER_CONTEXT)

    assert_raises(RuntimeError) { Practitioner.detail(206) }
    assert_equal CALLER_CONTEXT, client.current_context
  end

  def test_detail_empty_fields_are_nil_not_raised_or_invented
    replay("detail_empty")

    assert_equal({
      duz: 200, title: nil, service_section: nil, provider_class: nil,
      npi: nil, npi_entry_status: nil, dea_number: nil, dea_expires: nil
    }, Practitioner.detail(200))
  end

  # GETS^DIQ answers [ERROR] for an entry that does not exist.
  def test_detail_nil_when_read_errors
    client = replay("detail_unknown")

    assert_nil Practitioner.detail(999_999)
    assert_equal CapturedReplies.flow_calls(SLUG, "detail_unknown"), sent(client)
  end

  # 41.97 is the set "1:Yes": left empty, the NPI on file is withheld.
  def test_detail_withholds_npi_unless_release_authorized
    replay("detail_npi_not_released")

    result = Practitioner.detail(207)

    assert_nil result[:npi], "DUZ 207 has NPI 1234567893 on file and no release"
    assert_equal "PAT REG.", result[:title]
  end

  def test_detail_npi_nil_when_release_authorized_but_npi_field_empty
    replay("detail_released_no_npi")

    result = Practitioner.detail(1)

    assert_nil result[:npi]
    assert_equal "IRM", result[:service_section]
  end

  # 41.98 is a set (N:NEEDS ENTRY;E:EXEMPT;D:DONE): the reply carries D as
  # the internal and DONE as the external, and detail returns the label.
  def test_detail_returns_the_set_label_not_the_code_for_npi_entry_status
    replay("detail_full")

    assert_equal "DONE", Practitioner.detail(206)[:npi_entry_status]
  end

  def test_detail_logs_no_field_values
    replay("detail_full")
    secrets = %w[PHYSICIAN MEDICINE 1234567893 AP1234563]

    out, err = capture_io { Practitioner.detail(206) }
    secrets.each { |secret| refute_includes out + err, secret, "logged or printed a field value" }
  end

  # ^DD(200,54.2,0) is "STATE ISSUING DEA NUMBER^200.55P": a multiple, filed
  # under subfile 200.55, so DDR GETS on file 200 never returns a 54.2 row.
  def test_detail_does_not_request_or_publish_the_state_dea_multiple
    client = replay("detail_full")

    result = Practitioner.detail(206)

    refute result.key?(:dea_state)
    refute_includes Practitioner::DETAIL_FIELDS, "54.2"
    refute_includes sent(client).first.last.to_s, "54.2"
  end
end
