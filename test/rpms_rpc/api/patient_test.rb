# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/client"
require "rpms_rpc/api/patient"

# RpmsRpc::Patient mechanics a server cannot show: arguments refused before
# the wire, the age arithmetic, and that brief_header raises a broker
# error instead of answering nil (#363). Every RPC behaviour (search, find,
# find_by_ssn, brief_header, contact, update) is a live spec in
# test/live/patient_live_test.rb and patient_update_live_test.rb (ADR 0009).
#
# No double here returns RPMS data: NoWireClient fails any call that reaches
# it, and RaisingClient only raises.
class PatientTest < Minitest::Test
  # Any RPC that reaches this client is a test failure.
  class NoWireClient
    class WireReached < StandardError; end

    %i[call_rpc call_rpc_lines call_rpc_global_array].each do |name|
      define_method(name) { |rpc, *| raise WireReached, "#{rpc} reached the wire" }
    end
  end

  # A broker error a server cannot be made to raise on demand (<NOLINE> in
  # BEHOPTCX, an <UNDEFINED> in a routine). This double raises it; it never
  # replies.
  class RaisingClient
    def initialize(message, error: RpmsRpc::Client::RpcError) = (@message, @error = message, error)
    def call_rpc(*) = raise(@error, @message)
  end

  # Records what would go on the wire and answers that nothing is on file.
  class RecordingClient
    attr_reader :calls

    def initialize = (@calls = [])

    def call_rpc(rpc, *params)
      @calls << [ rpc, *params ]
      ""
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def use(client)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
  end

  # -- refused before the wire ----------------------------------------------

  def test_find_sends_nothing_for_a_blank_or_non_positive_dfn
    use NoWireClient.new
    [ nil, 0, -5, "" ].each { |dfn| assert_nil RpmsRpc::Patient.find(dfn), dfn.inspect }
  end

  def test_find_by_ssn_sends_nothing_for_a_blank_ssn
    use NoWireClient.new
    [ nil, "", " ", "--" ].each { |ssn| assert_nil RpmsRpc::Patient.find_by_ssn(ssn), ssn.inspect }
  end

  # -- shaped before the wire (#352) -----------------------------------------

  # ORWPT FULLSSN matches the "SSN" index exactly, and the index holds no
  # punctuation: a dashed SSN sent as given finds nobody.
  def test_find_by_ssn_sends_the_ssn_without_punctuation
    [ "000-00-9999", "000 00 9999", " 000009999 ", "000009999", 9999.to_s.rjust(9, "0") ].each do |ssn|
      use(client = RecordingClient.new)
      RpmsRpc::Patient.find_by_ssn(ssn)

      assert_equal [ [ "ORWPT FULLSSN", "000009999" ] ], client.calls, ssn.inspect
    end
  end

  def test_find_by_ssn_keeps_the_p_of_a_pseudo_ssn
    use(client = RecordingClient.new)
    RpmsRpc::Patient.find_by_ssn("000-00-9999P")

    assert_equal [ [ "ORWPT FULLSSN", "000009999P" ] ], client.calls
  end

  # ORWPT LIST ALL answers the names AFTER its from-text, so search sends the
  # string just before the text: the page then begins at the text itself.
  def test_search_starts_the_page_just_before_the_text
    { "MOUSE,MICKEY M" => "MOUSE,MICKEY L~", "DEMO" => "DEMN~", "A" => "@~" }.each do |text, from|
      use(client = RecordingClient.new)

      assert_equal [], RpmsRpc::Patient.search(text)
      assert_equal [ [ "ORWPT LIST ALL", from, "1" ] ], client.calls, text
    end
  end

  def test_search_with_no_text_starts_at_the_top_of_the_index
    [ nil, "" ].each do |text|
      use(client = RecordingClient.new)
      RpmsRpc::Patient.search(text)

      assert_equal [ [ "ORWPT LIST ALL", "", "1" ] ], client.calls, text.inspect
    end
  end

  def test_brief_header_sends_nothing_for_a_blank_or_non_positive_dfn
    use NoWireClient.new
    [ nil, 0, -5 ].each { |dfn| assert_nil RpmsRpc::Patient.brief_header(dfn), dfn.inspect }
  end

  def test_contact_sends_nothing_for_a_blank_or_non_positive_dfn
    use NoWireClient.new
    [ nil, 0, "-5" ].each { |dfn| assert_nil RpmsRpc::Patient.contact(dfn), dfn.inspect }
  end

  def test_contact_refuses_a_malformed_dfn_before_the_wire
    use NoWireClient.new
    [ nil, 0, "-5", "", 4.5, "42abc", " 42" ].each { |dfn| assert_nil RpmsRpc::Patient.contact(dfn), dfn.inspect }
  end

  # -- contact reads email where AG files it (#381) ---------------------------

  def gets_key(file, fields)
    RpmsRpc::DdrFileman.gets_entry_param(file: file, iens: "42,", fields: fields, flags: "IE").to_s
  end

  def seed_contact(mock, ihs: true)
    mock.seed(:ddr_gets_entry_data, gets_key("2", ".131;.132;.134"), <<~REPLY.chomp)
      [Data]
      2^42,^.131^406-555-0101^406-555-0101
      2^42,^.132^^
      2^42,^.134^406-555-0198^406-555-0198
    REPLY
    return unless ihs

    mock.seed(:ddr_gets_entry_data, gets_key("9000001", "1801;1802"), <<~REPLY.chomp)
      [Data]
      9000001^42,^1801^MSG 406-555-0100^MSG 406-555-0100
      9000001^42,^1802^una@example.test^una@example.test
    REPLY
  end

  def test_contact_reads_email_and_other_phone_from_ihs_patient
    seed_contact(RpmsRpc.mock!)

    assert_equal({ dfn: 42, phone_home: "406-555-0101", phone_work: nil, phone_cell: "406-555-0198",
                   phone_other: "MSG 406-555-0100", email: "una@example.test" },
                 RpmsRpc::Patient.contact(42))
  end

  def test_contact_is_nil_when_the_ihs_patient_read_fails
    seed_contact(RpmsRpc.mock!, ihs: false)

    assert_nil RpmsRpc::Patient.contact(42)
  end

  def test_update_takes_named_attributes_and_refuses_field_numbers_before_the_wire
    use NoWireClient.new

    assert_raises(RpmsRpc::Registration::AttributeNotOfferedError) do
      RpmsRpc::Patient.update(42, patient_fields: { ".133" => "una@example.test" })
    end
    assert_raises(RpmsRpc::Registration::AttributeNotOfferedError) { RpmsRpc::Patient.update(42, phone_cell: "1") }
  end

  def test_update_with_no_fields_sends_nothing
    use NoWireClient.new
    result = RpmsRpc::Patient.update(42)

    refute result[:success]
    assert_equal :no_fields, result[:error]
  end

# -- errors propagate (#363) ------------------------------------------------

# Before #363 these answered nil: a missing chart banner looked like a
# patient with no banner.
def test_brief_header_raises_when_the_rpc_is_not_served
  use RaisingClient.new("3 Unknown remote procedure: BEHOPTCX PTINFO", error: RpmsRpc::Client::RpcNotAvailableError)
  assert_raises(RpmsRpc::Client::RpcNotAvailableError) { RpmsRpc::Patient.brief_header(8791) }
end

def test_brief_header_raises_when_the_routine_is_missing
  use RaisingClient.new("M  ERROR=<NOLINE>PTINFO+22 BEHOPTCX")
  err = assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Patient.brief_header(8791) }
  assert_includes err.message, "NOLINE"
end

def test_brief_header_raises_any_other_m_error
    use RaisingClient.new("M  ERROR=<UNDEFINED>FOO+5^XYZ^")
    err = assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Patient.brief_header(8791) }
    assert_includes err.message, "UNDEFINED"
  end

  # -- age arithmetic --------------------------------------------------------

  def test_age_from_counts_whole_years_around_the_birthday
    dob = Date.new(1986, 7, 1)
    assert_equal 39, RpmsRpc::Patient.send(:age_from, dob, today: Date.new(2026, 6, 30)), "day before"
    assert_equal 40, RpmsRpc::Patient.send(:age_from, dob, today: Date.new(2026, 7, 1)), "on the day"
    assert_equal 40, RpmsRpc::Patient.send(:age_from, dob, today: Date.new(2026, 7, 2)), "day after"
    assert_equal 39, RpmsRpc::Patient.send(:age_from, dob, today: Date.new(2026, 5, 22))
    assert_nil RpmsRpc::Patient.send(:age_from, nil)
  end

  # -- address (DDR GETS ENTRY DATA, PATIENT #2) ----------------------------

  ADDRESS_FIELDS = ".111;.112;.113;.114;.115;.116;.1112"
  ADDRESS_KEYS = %i[dfn line1 line2 line3 city state state_ien zip zip_plus4].freeze
  ADDRESS_FIXTURE = {
    line1: "100 Example Street",
    line2: "SUITE 200",
    line3: "BUILDING B",
    city: "Exampleville",
    state: "EXAMPLE STATE",
    state_ien: 99,
    zip: "00000",
    zip_plus4: "00000-0000"
  }.freeze

  def gets_key_for(dfn, file, fields)
    RpmsRpc::DdrFileman.gets_entry_param(file: file, iens: "#{dfn},", fields: fields, flags: "IE").to_s
  end

  def seed_address(mock, dfn: 42, **overrides)
    values = ADDRESS_FIXTURE.merge(overrides)
    mock.seed(:ddr_gets_entry_data, gets_key_for(dfn, "2", ADDRESS_FIELDS), <<~REPLY.chomp)
      [Data]
      2^#{dfn},^.111^#{values[:line1]}^#{values[:line1]}
      2^#{dfn},^.112^#{values[:line2]}^#{values[:line2]}
      2^#{dfn},^.113^#{values[:line3]}^#{values[:line3]}
      2^#{dfn},^.114^#{values[:city]}^#{values[:city]}
      2^#{dfn},^.115^#{values[:state_ien]}^#{values[:state]}
      2^#{dfn},^.116^#{values[:zip]}^#{values[:zip]}
      2^#{dfn},^.1112^#{values[:zip_plus4].delete("-")}^#{values[:zip_plus4]}
    REPLY
    values
  end

  def assert_logs_no_secrets(secrets)
    out, err = capture_io { yield }
    combined = out + err
    secrets.each { |secret| refute_includes combined, secret.to_s, "logged or printed a field value" }
  end

  def test_address_maps_each_field_number
    seed_address(RpmsRpc.mock!)

    result = RpmsRpc::Patient.address(42)

    expected = { dfn: 42, **ADDRESS_FIXTURE }
    assert_equal ADDRESS_KEYS, result.keys
    assert_equal expected, result
  end

  # .1112 accepts 5 to 20 characters and ZIPOUT^VAFADDR prints 12345 or
  # 12345-6789: the field holds the whole ZIP+4, never a 4-digit suffix.
  def test_address_publishes_the_whole_zip_plus_four_under_an_honest_key
    seed_address(RpmsRpc.mock!, zip_plus4: "59101-1234")

    result = RpmsRpc::Patient.address(42)

    assert_equal "59101-1234", result[:zip_plus4]
    refute result.key?(:zip4)
  end

  def test_address_blank_or_nonpositive_id_sends_nothing
    use NoWireClient.new
    [ nil, 0, "-5", "", 4.5, "4.9", "42abc", " 42" ].each { |dfn| assert_nil RpmsRpc::Patient.address(dfn), dfn.inspect }
  end

  def test_address_reads_in_ciav_vuecentric_and_restores_the_callers_context
    mock = RpmsRpc.mock!
    caller_context = mock.current_context
    seed_address(mock)

    RpmsRpc::Patient.address(42)

    ddr_calls = mock.received_calls.select { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
    refute_empty ddr_calls
    ddr_calls.each do |call|
      assert_equal "CIAV VUECENTRIC", call[:context],
                   "address must read FileMan under CIAV VUECENTRIC"
    end
    assert_equal [ "CIAV VUECENTRIC", caller_context ], mock.context_binds
  end

  def test_address_restores_the_callers_context_when_the_read_raises
    mock = RpmsRpc.mock!
    caller_context = mock.current_context
    def mock.call_rpc(*) = raise(RpmsRpc::Client::RpcError, "boom")

    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Patient.address(42) }
    assert_equal caller_context, mock.current_context
  end

  def test_address_nil_state_ien_when_pointer_internal_is_not_a_positive_whole_number
    dfn = 42
    state_name = "EXAMPLE STATE"
    [ "0", "12abc" ].each do |bad_internal|
      RpmsRpc.reset!
      mock = RpmsRpc.mock!
      mock.seed(:ddr_gets_entry_data, gets_key_for(dfn, "2", ADDRESS_FIELDS), <<~REPLY.chomp)
        [Data]
        2^#{dfn},^.111^100 Example Street^100 Example Street
        2^#{dfn},^.112^^
        2^#{dfn},^.113^^
        2^#{dfn},^.114^Exampleville^Exampleville
        2^#{dfn},^.115^#{bad_internal}^#{state_name}
        2^#{dfn},^.116^00000^00000
        2^#{dfn},^.1112^000000000^00000-0000
      REPLY

      result = RpmsRpc::Patient.address(dfn)

      assert_nil result[:state_ien], "internal #{bad_internal.inspect}"
      assert_equal state_name, result[:state]
    end
  end

  def test_address_empty_fields_are_nil_not_raised_or_invented
    mock = RpmsRpc.mock!
    dfn = 42
    mock.seed(:ddr_gets_entry_data, gets_key_for(dfn, "2", ADDRESS_FIELDS), <<~REPLY.chomp)
      [Data]
      2^#{dfn},^.111^^
      2^#{dfn},^.112^^
      2^#{dfn},^.113^^
      2^#{dfn},^.114^^
      2^#{dfn},^.115^^
      2^#{dfn},^.116^^
      2^#{dfn},^.1112^^
    REPLY

    result = RpmsRpc::Patient.address(dfn)

    assert_equal ADDRESS_KEYS, result.keys
    assert_equal({ dfn: 42, line1: nil, line2: nil, line3: nil, city: nil, state: nil, state_ien: nil, zip: nil,
                   zip_plus4: nil }, result)

    mock.seed(:ddr_gets_entry_data, gets_key_for(43, "2", ADDRESS_FIELDS), "[Data]")
    assert_nil RpmsRpc::Patient.address(43)
  end

  def test_address_nil_when_read_errors
    mock = RpmsRpc.mock!
    mock.seed(:ddr_gets_entry_data, gets_key_for(42, "2", ADDRESS_FIELDS), "[ERROR]")
    assert_nil RpmsRpc::Patient.address(42)
    assert_nil RpmsRpc::Patient.address(99)
  end

  def test_address_logs_no_field_values
    values = seed_address(RpmsRpc.mock!)
    secrets = values.values_at(:line1, :line2, :line3, :city, :state, :zip, :zip_plus4).map(&:to_s)

    assert_logs_no_secrets(secrets) { RpmsRpc::Patient.address(42) }
  end

  # -- race (DDR GETS ENTRY DATA, PATIENT #2 field .06) ---------------------

  RACE_FIELDS = ".06"
  RACE_KEYS = %i[dfn race].freeze
  RACE_EXTERNAL = "EXAMPLE RACE CATEGORY"

  def seed_race(mock, dfn: 42, internal: "7", external: RACE_EXTERNAL)
    mock.seed(:ddr_gets_entry_data, gets_key_for(dfn, "2", RACE_FIELDS), <<~REPLY.chomp)
      [Data]
      2^#{dfn},^.06^#{internal}^#{external}
    REPLY
    external
  end

  def test_race_maps_each_field_number
    seed_race(RpmsRpc.mock!)

    result = RpmsRpc::Patient.race(42)

    assert_equal RACE_KEYS, result.keys
    assert_equal({ dfn: 42, race: RACE_EXTERNAL }, result)
  end

  def test_race_blank_or_nonpositive_id_sends_nothing
    use NoWireClient.new
    [ nil, 0, "-5", "", 4.5, "4.9", "42abc", " 42" ].each { |dfn| assert_nil RpmsRpc::Patient.race(dfn), dfn.inspect }
  end

  def test_race_reads_in_ciav_vuecentric_and_restores_the_callers_context
    mock = RpmsRpc.mock!
    caller_context = mock.current_context
    seed_race(mock)

    RpmsRpc::Patient.race(42)

    ddr_calls = mock.received_calls.select { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
    refute_empty ddr_calls
    ddr_calls.each do |call|
      assert_equal "CIAV VUECENTRIC", call[:context],
                   "race must read FileMan under CIAV VUECENTRIC"
    end
    assert_equal [ "CIAV VUECENTRIC", caller_context ], mock.context_binds
  end

  def test_race_restores_the_callers_context_when_the_read_raises
    mock = RpmsRpc.mock!
    caller_context = mock.current_context
    def mock.call_rpc(*) = raise(RpmsRpc::Client::RpcError, "boom")

    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Patient.race(42) }
    assert_equal caller_context, mock.current_context
  end

  def test_contact_reads_in_ciav_vuecentric_and_restores_the_callers_context
    mock = RpmsRpc.mock!
    caller_context = mock.current_context
    seed_contact(mock)

    RpmsRpc::Patient.contact(42)

    ddr_calls = mock.received_calls.select { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
    refute_empty ddr_calls
    ddr_calls.each do |call|
      assert_equal "CIAV VUECENTRIC", call[:context],
                   "contact must read FileMan under CIAV VUECENTRIC"
    end
    assert_equal [ "CIAV VUECENTRIC", caller_context ], mock.context_binds
  end

  def test_contact_restores_the_callers_context_when_the_read_raises
    mock = RpmsRpc.mock!
    caller_context = mock.current_context
    def mock.call_rpc(*) = raise(RpmsRpc::Client::RpcError, "boom")

    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Patient.contact(42) }
    assert_equal caller_context, mock.current_context
  end

  def test_race_empty_fields_are_nil_not_raised_or_invented
    mock = RpmsRpc.mock!
    dfn = 42
    mock.seed(:ddr_gets_entry_data, gets_key_for(dfn, "2", RACE_FIELDS), <<~REPLY.chomp)
      [Data]
      2^#{dfn},^.06^^
    REPLY

    result = RpmsRpc::Patient.race(dfn)

    assert_equal RACE_KEYS, result.keys
    assert_equal({ dfn: 42, race: nil }, result)

    mock.seed(:ddr_gets_entry_data, gets_key_for(43, "2", RACE_FIELDS), "[Data]")
    assert_nil RpmsRpc::Patient.race(43)
  end

  def test_race_nil_when_read_errors
    mock = RpmsRpc.mock!
    mock.seed(:ddr_gets_entry_data, gets_key_for(42, "2", RACE_FIELDS), "[ERROR]")
    assert_nil RpmsRpc::Patient.race(42)
    assert_nil RpmsRpc::Patient.race(99)
  end

  def test_race_logs_no_field_values
    external = seed_race(RpmsRpc.mock!)

    assert_logs_no_secrets([ external ]) { RpmsRpc::Patient.race(42) }
  end
end
