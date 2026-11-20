# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require "rpms_rpc/compatibility"
require "rpms_rpc/retry_safety"
require "set"
require_relative "../orwpce_read_helpers"
require_relative "../captured_replies"

CLINICAL_EVENT_AVAILABLE = begin
  require "rpms_rpc/api/clinical_event"
  true
rescue LoadError
  false
end

# Issue #286: ORWPCE read + wiring RPCs on RpmsRpc::ClinicalEvent (no writes).
#
# When note IEN is a positive integer, ORWPCE GET VISIT, HASVISIT, and PCE4NOTE take
# the visit from ^TIU(8925,note,0) piece 3 and ignore DFN on the broker. So on that
# path ClinicalEvent enforces the patient scope itself (issue #531): visit_for_note,
# has_visit?, visit_status, and pce_for_note first read the note's patient with
# TIU GET ALERT INFO (under OR CPRS GUI CHART) and send the ORWPCE RPC only when it
# is the DFN passed. Any other answer raises ClinicalEvent::NotePatientMismatchError
# and sends no ORWPCE RPC. Note 0 looks the visit up by DFN on the server and makes
# no ownership read. note_visit_string takes no DFN and is unscoped.
class ClinicalEventTest < Minitest::Test
  include OrwpceReadHelpers

  Compatibility = RpmsRpc::Compatibility

  NOTE_IEN = "3"
  DFN = "4"
  GUARDED_METHODS = %i[visit_for_note has_visit? visit_status pce_for_note].freeze
  VISIT_STRING = ""
  LOCATION = "6"
  VISIT_DATETIME = "3260312.09"
  WELL_FORMED_VISIT_STRING = "3;3260902.0255;A"
  MALFORMED_VISIT_STRINGS = [ ";;", ";3260902.0255;A", "abc;3260902.0255;A", "3;;A" ].freeze

  def teardown
    RpmsRpc.reset!
  end

  def before_setup
    super
    flunk "spec(#286): add lib/rpms_rpc/api/clinical_event.rb" unless CLINICAL_EVENT_AVAILABLE
  end

  def clinical_event
    RpmsRpc::ClinicalEvent
  end

  def use(client)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
  end

  SLUG = "clinical-event"

  # The registry as the release had it when the flows were recorded: ClinicalEvent asks the client
  # which RPCs the server serves before each read, and the release the capture names (release_tag)
  # answered every RPC the capture recorded.
  def self.served
    @served ||= CapturedReplies.file(SLUG).fetch("captures").to_set { |c| c.fetch("rpc") }
  end

  # A CiaClient answering a flow recorded on a published release
  # (test/fixtures/captured_replies/clinical-event.yml, spec
  # tools/captured_replies/clinical-event.rb), and the registry as the build has it.
  class BuildReplay < CapturedReplies::ReplayCiaClient
    def served_rpcs(names) = names.to_set & ClinicalEventTest.served
  end

  def replay(flow)
    @flow = flow
    use(BuildReplay.new(CapturedReplies.flow_script(SLUG, flow)))
    RpmsRpc.client
  end

  def replayed = RpmsRpc.client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
  def assert_sent_as_recorded = assert_equal(CapturedReplies.flow_calls(SLUG, @flow), replayed, @flow)

  # -- broker parameter order (from capture inputs) ---------------------------

  def test_visit_for_note_sends_orwpce_get_visit_params_from_capture
    client = RecordingClient.new
    use(client)
    clinical_event.visit_for_note(NOTE_IEN, DFN, VISIT_STRING)

    assert_guarded_calls client, NOTE_IEN, [ "ORWPCE GET VISIT", NOTE_IEN, DFN, VISIT_STRING ]
  end

  def test_has_visit_sends_orwpce_hasvisit_params_from_capture
    client = RecordingClient.new
    use(client)
    clinical_event.has_visit?(NOTE_IEN, DFN, "", "")

    assert_guarded_calls client, NOTE_IEN, [ "ORWPCE HASVISIT", NOTE_IEN, DFN, "", "" ]
  end

  def test_has_visit_lookup_by_location_sends_orwpce_hasvisit_params_from_capture
    client = RecordingClient.new
    use(client)
    clinical_event.has_visit?("0", "990003", LOCATION, VISIT_DATETIME)

    assert_equal [ [ "ORWPCE HASVISIT", "0", "990003", LOCATION, VISIT_DATETIME ] ], client.calls
  end

  def test_visit_for_note_note_zero_with_visit_string_sends_capture_params
    cap = load_unmapped_capture("ORWPCE GET VISIT").fetch("captures").find do |c|
      c.fetch("inputs").first == "0"
    end
    refute_nil cap
    client = RecordingClient.new
    use(client)
    clinical_event.visit_for_note(*cap.fetch("inputs"))

    assert_equal [ [ "ORWPCE GET VISIT", *cap.fetch("inputs") ] ], client.calls
  end

  def test_visit_status_sends_orwpce_hasvisit_params_from_capture
    client = RecordingClient.new
    use(client)
    clinical_event.visit_status(NOTE_IEN, DFN, "", "")

    assert_guarded_calls client, NOTE_IEN, [ "ORWPCE HASVISIT", NOTE_IEN, DFN, "", "" ]
  end

  def test_visit_status_lookup_by_location_sends_orwpce_hasvisit_params_from_capture
    client = RecordingClient.new
    use(client)
    clinical_event.visit_status("0", "990003", LOCATION, VISIT_DATETIME)

    assert_equal [ [ "ORWPCE HASVISIT", "0", "990003", LOCATION, VISIT_DATETIME ] ], client.calls
  end

  def test_note_visit_string_sends_orwpce_notevstr_note_ien
    client = RecordingClient.new
    use(client)
    clinical_event.note_visit_string(NOTE_IEN)

    assert_equal [ [ "ORWPCE NOTEVSTR", NOTE_IEN ] ], client.calls
  end

  def test_pce_for_note_sends_orwpce_pce4note_params_from_capture
    client = RecordingClient.new
    use(client)
    clinical_event.pce_for_note(NOTE_IEN, DFN, VISIT_STRING)

    assert_guarded_calls client, NOTE_IEN, [ "ORWPCE PCE4NOTE", NOTE_IEN, DFN, VISIT_STRING ]
  end

  def test_immunization_types_without_date_sends_no_params
    client = RecordingClient.new
    use(client)
    clinical_event.immunization_types

    assert_equal [ [ "ORWPCE GET IMMUNIZATION TYPE" ] ], client.calls
  end

  def test_immunization_types_with_date_sends_the_fileman_date
    client = RecordingClient.new
    use(client)
    clinical_event.immunization_types("3261022")

    assert_equal [ [ "ORWPCE GET IMMUNIZATION TYPE", "3261022" ] ], client.calls
  end

  def test_immunization_types_with_integer_fileman_date_sends_string_param
    client = RecordingClient.new
    use(client)
    clinical_event.immunization_types(3_261_022)

    assert_equal [ [ "ORWPCE GET IMMUNIZATION TYPE", "3261022" ] ], client.calls
  end

  def test_skin_test_types_without_date_sends_no_params
    client = RecordingClient.new
    use(client)
    clinical_event.skin_test_types

    assert_equal [ [ "ORWPCE GET SKIN TEST TYPE" ] ], client.calls
  end

  def test_skin_test_types_with_integer_fileman_date_sends_string_param
    client = RecordingClient.new
    use(client)
    clinical_event.skin_test_types(3_261_022)

    assert_equal [ [ "ORWPCE GET SKIN TEST TYPE", "3261022" ] ], client.calls
  end

  def test_exam_types_sends_no_params
    client = RecordingClient.new
    use(client)
    clinical_event.exam_types

    assert_equal [ [ "ORWPCE GET EXAM TYPE" ] ], client.calls
  end

  def test_education_topics_sends_no_params
    client = RecordingClient.new
    use(client)
    clinical_event.education_topics

    assert_equal [ [ "ORWPCE GET EDUCATION TOPICS" ] ], client.calls
  end

  def test_health_factor_types_without_add_categories_sends_no_params
    client = RecordingClient.new
    use(client)
    clinical_event.health_factor_types

    assert_equal [ [ "ORWPCE GET HEALTH FACTORS TY" ] ], client.calls
  end

  def test_health_factor_types_with_add_categories_sends_one
    client = RecordingClient.new
    use(client)
    clinical_event.health_factor_types(add_categories: true)

    assert_equal [ [ "ORWPCE GET HEALTH FACTORS TY", "1" ] ], client.calls
  end

  def test_visit_for_note_sends_nothing_for_invalid_note_ien
    use NoWireClient.new
    INVALID_NOTE_IDS.each do |bad|
      assert_nil clinical_event.visit_for_note(bad, DFN, VISIT_STRING), bad.inspect
    end
  end

  def test_visit_for_note_sends_nothing_for_invalid_dfn
    use NoWireClient.new
    INVALID_DFN_IDS.each do |bad|
      assert_nil clinical_event.visit_for_note(NOTE_IEN, bad, VISIT_STRING), bad.inspect
    end
  end

  def test_visit_for_note_note_zero_without_visit_string_makes_no_call
    use NoWireClient.new
    assert_nil clinical_event.visit_for_note(0, DFN, VISIT_STRING)
    assert_nil clinical_event.visit_for_note("0", DFN, "")
  end

  def test_has_visit_sends_nothing_for_invalid_note_ien
    use NoWireClient.new
    INVALID_NOTE_IDS.each do |bad|
      refute clinical_event.has_visit?(bad, DFN, "", ""), bad.inspect
      assert_nil clinical_event.visit_status(bad, DFN, "", ""), bad.inspect
    end
  end

  def test_has_visit_sends_nothing_for_invalid_dfn
    use NoWireClient.new
    INVALID_DFN_IDS.each do |bad|
      refute clinical_event.has_visit?(NOTE_IEN, bad, "", ""), bad.inspect
      assert_nil clinical_event.visit_status(NOTE_IEN, bad, "", ""), bad.inspect
    end
  end

  def test_has_visit_note_zero_without_location_makes_no_call
    use NoWireClient.new
    refute clinical_event.has_visit?("0", DFN, "", "")
    assert_nil clinical_event.visit_status("0", DFN, "", "")
    refute clinical_event.has_visit?("0", DFN, LOCATION, "")
    assert_nil clinical_event.visit_status("0", DFN, LOCATION, "")
  end

  def test_note_visit_string_sends_nothing_for_invalid_note_ien
    use NoWireClient.new
    (INVALID_NOTE_IDS + [ 0, "0" ]).each do |bad|
      assert_nil clinical_event.note_visit_string(bad), bad.inspect
    end
  end

  def test_pce_for_note_sends_nothing_for_invalid_note_ien
    use NoWireClient.new
    INVALID_NOTE_IDS.each do |bad|
      assert_nil clinical_event.pce_for_note(bad, DFN, VISIT_STRING), bad.inspect
    end
  end

  def test_pce_for_note_sends_nothing_for_invalid_dfn
    use NoWireClient.new
    INVALID_DFN_IDS.each do |bad|
      assert_nil clinical_event.pce_for_note(NOTE_IEN, bad, VISIT_STRING), bad.inspect
    end
  end

  def test_pce_for_note_note_zero_without_visit_string_makes_no_call
    use NoWireClient.new
    assert_nil clinical_event.pce_for_note(0, DFN, VISIT_STRING)
    assert_nil clinical_event.pce_for_note("0", DFN, "")
  end

  def test_pce_for_note_note_zero_with_visit_string_sends_capture_params
    cap = load_unmapped_capture("ORWPCE PCE4NOTE").fetch("captures").find do |c|
      c.fetch("inputs").first == "0"
    end
    refute_nil cap
    client = RecordingClient.new
    use(client)
    clinical_event.pce_for_note(*cap.fetch("inputs"))

    assert_equal [ [ "ORWPCE PCE4NOTE", *cap.fetch("inputs") ] ], client.calls
  end

  def test_visit_for_note_positive_note_rejects_malformed_visit_string
    MALFORMED_VISIT_STRINGS.each do |bad|
      client = RecordingClient.new
      use(client)
      assert_nil clinical_event.visit_for_note(NOTE_IEN, DFN, bad), bad.inspect
      assert_empty client.calls, bad.inspect
    end
  end

  def test_visit_for_note_positive_note_sends_blank_visit_string
    client = RecordingClient.new
    use(client)
    clinical_event.visit_for_note(NOTE_IEN, DFN, "")

    assert_guarded_calls client, NOTE_IEN, [ "ORWPCE GET VISIT", NOTE_IEN, DFN, "" ]
  end

  def test_visit_for_note_positive_note_sends_empty_string_not_nil_for_nil_visit_string
    client = RecordingClient.new
    use(client)
    clinical_event.visit_for_note(NOTE_IEN, DFN, nil)

    assert_guarded_calls client, NOTE_IEN, [ "ORWPCE GET VISIT", NOTE_IEN, DFN, "" ]
    refute orwpce_calls(client).first[3].nil?, "visit_string param must be empty string, not nil"
  end

  def test_pce_for_note_positive_note_sends_empty_string_not_nil_for_nil_visit_string
    client = RecordingClient.new
    use(client)
    clinical_event.pce_for_note(NOTE_IEN, DFN, nil)

    assert_guarded_calls client, NOTE_IEN, [ "ORWPCE PCE4NOTE", NOTE_IEN, DFN, "" ]
    refute orwpce_calls(client).first[3].nil?
  end

  def test_has_visit_positive_note_sends_empty_strings_not_nil_for_nil_location_and_datetime
    client = RecordingClient.new
    use(client)
    clinical_event.has_visit?(NOTE_IEN, DFN, nil, nil)

    assert_guarded_calls client, NOTE_IEN, [ "ORWPCE HASVISIT", NOTE_IEN, DFN, "", "" ]
    refute orwpce_calls(client).first[3].nil?
    refute orwpce_calls(client).first[4].nil?
  end

  def test_visit_status_positive_note_sends_empty_strings_not_nil_for_nil_location_and_datetime
    client = RecordingClient.new
    use(client)
    clinical_event.visit_status(NOTE_IEN, DFN, nil, nil)

    assert_guarded_calls client, NOTE_IEN, [ "ORWPCE HASVISIT", NOTE_IEN, DFN, "", "" ]
    refute orwpce_calls(client).first[3].nil?
    refute orwpce_calls(client).first[4].nil?
  end

  def test_visit_for_note_positive_note_sends_well_formed_visit_string
    client = RecordingClient.new
    use(client)
    clinical_event.visit_for_note(NOTE_IEN, DFN, WELL_FORMED_VISIT_STRING)

    assert_guarded_calls client, NOTE_IEN, [ "ORWPCE GET VISIT", NOTE_IEN, DFN, WELL_FORMED_VISIT_STRING ]
  end

  def test_has_visit_positive_note_rejects_malformed_location_or_datetime
    client = RecordingClient.new
    use(client)
    refute clinical_event.has_visit?(NOTE_IEN, DFN, "abc", "")
    assert_empty client.calls
    refute clinical_event.has_visit?(NOTE_IEN, DFN, "", "not-fileman")
    assert_empty client.calls
    refute clinical_event.has_visit?(NOTE_IEN, DFN, "0", VISIT_DATETIME)
    assert_empty client.calls
    assert_nil clinical_event.visit_status(NOTE_IEN, DFN, "abc", "")
    assert_empty client.calls
  end

  def test_has_visit_positive_note_sends_blank_location_and_datetime
    client = RecordingClient.new
    use(client)
    clinical_event.has_visit?(NOTE_IEN, DFN, "", "")

    assert_guarded_calls client, NOTE_IEN, [ "ORWPCE HASVISIT", NOTE_IEN, DFN, "", "" ]
  end

  def test_has_visit_positive_note_sends_well_formed_location_and_datetime
    client = RecordingClient.new
    use(client)
    clinical_event.has_visit?(NOTE_IEN, DFN, "3", "3260902.0255")

    assert_guarded_calls client, NOTE_IEN, [ "ORWPCE HASVISIT", NOTE_IEN, DFN, "3", "3260902.0255" ]
  end

  def test_pce_for_note_positive_note_rejects_malformed_visit_string
    MALFORMED_VISIT_STRINGS.each do |bad|
      client = RecordingClient.new
      use(client)
      assert_nil clinical_event.pce_for_note(NOTE_IEN, DFN, bad), bad.inspect
      assert_empty client.calls, bad.inspect
    end
  end

  def test_pce_for_note_positive_note_sends_well_formed_visit_string
    client = RecordingClient.new
    use(client)
    clinical_event.pce_for_note(NOTE_IEN, DFN, WELL_FORMED_VISIT_STRING)

    assert_guarded_calls client, NOTE_IEN, [ "ORWPCE PCE4NOTE", NOTE_IEN, DFN, WELL_FORMED_VISIT_STRING ]
  end

  def test_immunization_types_with_blank_date_sends_empty_string
    client = RecordingClient.new
    use(client)
    clinical_event.immunization_types("")

    assert_equal [ [ "ORWPCE GET IMMUNIZATION TYPE", "" ] ], client.calls
  end

  def test_immunization_types_with_invalid_date_makes_no_call_and_returns_empty
    client = RecordingClient.new(served: IN_SCOPE_RPCS)
    use(client)
    assert_equal [], clinical_event.immunization_types("not-a-date")
    assert_empty client.calls
  end

  def test_skin_test_types_with_blank_date_sends_empty_string
    client = RecordingClient.new
    use(client)
    clinical_event.skin_test_types("")

    assert_equal [ [ "ORWPCE GET SKIN TEST TYPE", "" ] ], client.calls
  end

  def test_skin_test_types_with_invalid_date_makes_no_call_and_returns_empty
    client = RecordingClient.new(served: IN_SCOPE_RPCS)
    use(client)
    assert_equal [], clinical_event.skin_test_types("not-a-date")
    assert_empty client.calls
  end

  # -- lock polarity (reads only) -------------------------------------------

  READ_FLOWS = {
    visit_for_note: [ "visit_for_note_3", [ NOTE_IEN, DFN, VISIT_STRING ] ],
    has_visit?: [ "has_visit_3", [ NOTE_IEN, DFN, "", "" ] ],
    visit_status: [ "has_visit_3", [ NOTE_IEN, DFN, "", "" ] ],
    note_visit_string: [ "note_visit_string_3", [ NOTE_IEN ] ],
    pce_for_note: [ "pce_for_note_3", [ NOTE_IEN, DFN, VISIT_STRING ] ],
    immunization_types: [ "immunization_types", [] ],
    skin_test_types: [ "skin_test_types", [] ],
    exam_types: [ "exam_types", [] ],
    education_topics: [ "education_topics", [] ],
    health_factor_types: [ "health_factor_types", [] ]
  }.freeze

  READ_FLOWS.each do |method, (flow, args)|
    define_method("test_#{method}_never_sends_a_write_or_lock_rpc") do
      replay(flow)
      clinical_event.public_send(method, *args)

      write_calls = replayed.map(&:first).grep(WRITE_RPC_PATTERN)
      assert_empty write_calls, "#{method} must not send write/lock RPCs; got #{write_calls.join(", ")}"
    end
  end

  # -- compatibility + served_rpcs gating -----------------------------------

  def test_required_rpcs_lists_every_in_scope_orwpce_read_under_clinical_event
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    listed = doc.fetch("modules").fetch(MODULE_NAME)
    missing = REQUIRED_RPCS - listed
    assert_empty missing, "required_rpcs.json must list:\n#{missing.join("\n")}"
  end

  def test_compatibility_reports_missing_orwpce_reads_when_the_registry_lacks_them
    required = {
      "build" => "bcer-test",
      "modules" => { MODULE_NAME => IN_SCOPE_RPCS }
    }
    served = IN_SCOPE_RPCS - [ "ORWPCE GET VISIT", "ORWPCE PCE4NOTE" ]
    client = RecordingClient.new(served: served)
    report = Compatibility.check(client, required: required)

    refute_predicate report, :ok?
    assert_equal [ "ORWPCE GET VISIT", "ORWPCE PCE4NOTE" ].sort,
                 report.missing.fetch(MODULE_NAME).sort
  end

  def test_visit_for_note_makes_no_call_when_orwpce_get_visit_is_not_served
    client = RecordingClient.new(served: REQUIRED_RPCS - [ "ORWPCE GET VISIT" ])
    use(client)
    assert_nil clinical_event.visit_for_note(NOTE_IEN, DFN, VISIT_STRING)
    assert_empty orwpce_calls(client)
  end

  def test_exam_types_returns_empty_when_orwpce_get_exam_type_is_not_served
    client = RecordingClient.new(served: REQUIRED_RPCS - [ "ORWPCE GET EXAM TYPE" ])
    use(client)
    assert_equal [], clinical_event.exam_types
    assert_empty client.calls
  end

  # -- retry safety -----------------------------------------------------------

  def test_read_helpers_are_classified_read
    %i[
      visit_for_note has_visit? visit_status note_visit_string pce_for_note
      immunization_types skin_test_types exam_types education_topics health_factor_types
    ].each do |method|
      assert_equal :read, RpmsRpc::RetrySafety.for(clinical_event, method),
                   "ClinicalEvent.#{method} must be :read"
    end
  end

  # Wire-backed API returns, on the build's replies -----------------------------

  def test_visit_for_note_returns_the_visit_ien_the_build_reads_from_the_note
    replay("visit_for_note_3")

    assert_equal 4, clinical_event.visit_for_note("3", "4", "")
    assert_sent_as_recorded
  end

  def test_visit_for_note_lookup_by_location_finding_none_returns_nil
    replay("visit_for_note_lookup")

    assert_nil clinical_event.visit_for_note("0", "990003", "6;3260312.09;A")
    assert_sent_as_recorded
  end

  def test_a_note_asked_for_another_patient_is_refused_before_orwpce
    replay("visit_for_note_other_patient")

    error = assert_raises(clinical_event::NotePatientMismatchError) { clinical_event.visit_for_note("3", "5", "") }
    assert_equal :mismatch, error.reason
    assert_empty orwpce_calls_sent
    assert_sent_as_recorded
  end

  def test_note_visit_string_returns_the_parsed_visit_string
    replay("note_visit_string_3")

    row = clinical_event.note_visit_string("3")
    assert_equal 3, row[:location_ien]
    assert_equal "3260902.0255", row[:datetime_raw]
    assert_equal "A", row[:service_category]
    assert_sent_as_recorded
  end

  def test_has_visit_is_true_for_notes_with_a_visit
    %w[3 5].each do |note|
      replay("has_visit_#{note}")
      assert clinical_event.has_visit?(note, "4", "", ""), note
      assert_sent_as_recorded
    end
  end

  def test_visit_status_returns_stand_alone_for_a_visit_not_tied_to_an_appointment
    replay("has_visit_3")

    assert_equal :stand_alone, clinical_event.visit_status("3", "4", "", "")
  end

  # HASVISIT answers -1 for a location lookup that finds no visit.
  def test_has_visit_and_visit_status_read_minus_one_as_no_visit
    lookup = [ "0", "990003", LOCATION, VISIT_DATETIME ]
    replay("has_visit_lookup")
    refute clinical_event.has_visit?(*lookup)
    assert_sent_as_recorded

    replay("has_visit_lookup")
    assert_equal :none, clinical_event.visit_status(*lookup)
  end

  def test_pce_for_note_rich_capture_header_author_and_modeled_fields
    replay("pce_for_note_3")

    bundle = clinical_event.pce_for_note("3", "4", "")
    header = bundle.fetch(:header)

    refute header.key?(:visit_ien)
    assert_equal 4, header[:author_ien]

    pov = bundle.fetch(:diagnoses).find { |r| r[:icd_code] == "J20.9" }
    assert_equal "Acute bronchitis | ", pov[:narrative]
    assert_equal "4", pov[:provider_ien]

    cpt = bundle.fetch(:procedures).first
    assert_equal "Parenteral Supp Not Othrws C", cpt[:narrative]

    imm = bundle.fetch(:immunizations).find { |r| r[:ien] == "272" }
    assert_equal "Influenza, adjuvanted, trivalent, injectable, preservative free", imm[:name]
    assert_sent_as_recorded
  end

  def test_pce_for_note_note5_author_ien_is_not_visit_ien_from_get_visit
    replay("pce_for_note_5")
    header = clinical_event.pce_for_note("5", "4", "").fetch(:header)
    refute header.key?(:visit_ien)
    assert_equal 4, header[:author_ien]

    replay("visit_for_note_5")
    assert_equal 5, clinical_event.visit_for_note("5", "4", "")
  end

  def orwpce_calls_sent = replayed.map(&:first).grep(/\AORWPCE /)
end
