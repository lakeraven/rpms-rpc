# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/client"
require "rpms_rpc/api/patient"
require_relative "../captured_replies"

# RpmsRpc::Patient mechanics a server cannot show: arguments refused before
# the wire, the age arithmetic, and that brief_header raises a broker
# error instead of answering nil (#363). Every RPC behaviour (search, find,
# find_by_ssn, brief_header, contact, update) is a live spec in
# test/live/patient_live_test.rb and patient_update_live_test.rb (ADR 0009).
#
# No double here returns RPMS data: NoWireClient fails any call that reaches
# it, and RaisingClient only raises. address, contact and race replay replies
# captured from the pinned build (CapturedReplies::ReplayCiaClient).
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

  # -- replayed replies --------------------------------------------------------

  # DDR GETS ENTRY DATA replies captured for synthetic DFN 990055 (every
  # address and contact piece filled), seed DFN 2 (every piece empty) and
  # DFN 5 (no PATIENT entry): test/fixtures/captured_replies/patient-address-contact.yml.
  READS = "patient-address-contact"
  RACE = "patient-race"
  CALLER_CONTEXT = "OR CPRS GUI CHART"

  def replay(slug, flow, from: CALLER_CONTEXT)
    client = CapturedReplies::ReplayCiaClient.new(flow ? CapturedReplies.flow_script(slug, flow) : {})
    client.create_context(from)
    use(client)
    client
  end

  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
  def binds(client) = client.calls.select { |c| c[:rpc] == :create_context }.map { |c| c[:params].first }.drop(1)

  # -- contact reads email where AG files it (#381) ---------------------------

  def test_contact_reads_email_and_other_phone_from_ihs_patient
    client = replay(READS, "contact_full")

    assert_equal({ dfn: 990_055, phone_home: "406-555-1055", phone_work: nil, phone_cell: "406-555-0198",
                   phone_other: "MSG 406-555-0100", email: "synthetic.patient@example.test" },
                 RpmsRpc::Patient.contact(990_055))
    assert_equal CapturedReplies.flow_calls(READS, "contact_full"), sent(client)
  end

  def test_contact_empty_fields_are_nil
    replay(READS, "contact_empty")

    assert_equal({ dfn: 2, phone_home: nil, phone_work: nil, phone_cell: nil, phone_other: nil, email: nil },
                 RpmsRpc::Patient.contact(2))
  end

  # GETS^DIQ answers [ERROR] for a DFN with no PATIENT entry; IHS PATIENT is not read.
  def test_contact_is_nil_when_the_patient_read_fails
    client = replay(READS, "contact_unknown")

    assert_nil RpmsRpc::Patient.contact(5)
    assert_equal CapturedReplies.flow_calls(READS, "contact_unknown"), sent(client)
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

  ADDRESS_KEYS = %i[dfn line1 line2 line3 city state state_ien zip zip_plus4].freeze

  def test_address_maps_each_field_number
    client = replay(READS, "address_full")

    result = RpmsRpc::Patient.address(990_055)

    assert_equal ADDRESS_KEYS, result.keys
    assert_equal({ dfn: 990_055, line1: "485 NORTHFIELD ST", line2: "UNIT 4", line3: "BLDG C", city: "ANYWHERE",
                   state: "MONTANA", state_ien: 27, zip: "59000", zip_plus4: "59000-1234" }, result)
    assert_equal CapturedReplies.flow_calls(READS, "address_full"), sent(client)
  end

  # .1112 accepts 5 to 20 characters and ZIPOUT^VAFADDR prints 12345 or
  # 12345-6789: the field holds the whole ZIP+4, never a 4-digit suffix. The
  # reply carries 590001234 internal and 59000-1234 external.
  def test_address_publishes_the_whole_zip_plus_four_under_an_honest_key
    replay(READS, "address_full")

    result = RpmsRpc::Patient.address(990_055)

    assert_equal "59000-1234", result[:zip_plus4]
    refute result.key?(:zip4)
  end

  def test_address_blank_or_nonpositive_id_sends_nothing
    use NoWireClient.new
    [ nil, 0, "-5", "", 4.5, "4.9", "42abc", " 42" ].each { |dfn| assert_nil RpmsRpc::Patient.address(dfn), dfn.inspect }
  end

  def test_address_contact_and_race_read_in_ciav_vuecentric_and_restore_the_callers_context
    { "address_full" => -> { RpmsRpc::Patient.address(990_055) },
      "contact_full" => -> { RpmsRpc::Patient.contact(990_055) } }.each do |flow, read|
      client = replay(READS, flow)
      read.call

      assert_equal [ "CIAV VUECENTRIC", CALLER_CONTEXT ], binds(client), flow
      assert_equal :create_context, client.calls[1][:rpc], "#{flow}: bound before the first read"
      assert_equal CALLER_CONTEXT, client.current_context
    end
    client = replay(RACE, "race_on_file")
    RpmsRpc::Patient.race(4)
    assert_equal [ "CIAV VUECENTRIC", CALLER_CONTEXT ], binds(client), "race"
  end

  # A lost wire: the replay client has no reply to give, so the read raises.
  def test_address_contact_and_race_restore_the_callers_context_when_the_read_raises
    { address: -> { RpmsRpc::Patient.address(990_055) }, contact: -> { RpmsRpc::Patient.contact(990_055) },
      race: -> { RpmsRpc::Patient.race(4) } }.each do |name, read|
      client = replay(READS, nil)

      assert_raises(RuntimeError, name) { read.call }
      assert_equal CALLER_CONTEXT, client.current_context, name
    end
  end

  def test_address_empty_fields_are_nil_not_raised_or_invented
    replay(READS, "address_empty")

    result = RpmsRpc::Patient.address(2)

    assert_equal ADDRESS_KEYS, result.keys
    assert_equal({ dfn: 2, line1: nil, line2: nil, line3: nil, city: nil, state: nil, state_ien: nil, zip: nil,
                   zip_plus4: nil }, result)
  end

  # GETS^DIQ answers [ERROR] for a DFN with no PATIENT entry.
  def test_address_nil_when_read_errors
    replay(READS, "address_unknown")

    assert_nil RpmsRpc::Patient.address(5)
  end

  def test_address_logs_no_field_values
    replay(READS, "address_full")
    secrets = [ "485 NORTHFIELD ST", "UNIT 4", "BLDG C", "ANYWHERE", "MONTANA", "59000-1234" ]

    out, err = capture_io { RpmsRpc::Patient.address(990_055) }
    secrets.each { |secret| refute_includes out + err, secret, "logged or printed a field value" }
  end

  # -- race (DDR GETS ENTRY DATA, PATIENT #2 field .06) ---------------------
  #
  # Replies captured for demo DFN 4 (.06 on file) and DFN 3 (none):
  # test/fixtures/captured_replies/patient-race.yml.

  RACE_KEYS = %i[dfn race].freeze

  def test_race_maps_each_field_number
    client = replay(RACE, "race_on_file")

    result = RpmsRpc::Patient.race(4)

    assert_equal RACE_KEYS, result.keys
    assert_equal({ dfn: 4, race: "AMERICAN INDIAN OR ALASKA NATIVE" }, result)
    assert_equal CapturedReplies.flow_calls(RACE, "race_on_file"), sent(client)
  end

  def test_race_blank_or_nonpositive_id_sends_nothing
    use NoWireClient.new
    [ nil, 0, "-5", "", 4.5, "4.9", "42abc", " 42" ].each { |dfn| assert_nil RpmsRpc::Patient.race(dfn), dfn.inspect }
  end

  def test_race_empty_fields_are_nil_not_raised_or_invented
    replay(RACE, "race_blank")

    assert_equal({ dfn: 3, race: nil }, RpmsRpc::Patient.race(3))
  end

  # The [ERROR] GETS^DIQ answered for DFN 5's address read: the same reply
  # any DDR GETS of a DFN with no PATIENT entry gets.
  def test_race_nil_when_read_errors
    use(CapturedReplies::ReplayCiaClient.new("DDR GETS ENTRY DATA" => [ CapturedReplies.raw(READS, "address_unknown/1") ]))

    assert_nil RpmsRpc::Patient.race(5)
  end

  def test_race_logs_no_field_values
    replay(RACE, "race_on_file")

    out, err = capture_io { RpmsRpc::Patient.race(4) }
    refute_includes out + err, "AMERICAN INDIAN OR ALASKA NATIVE", "logged or printed a field value"
  end
end
