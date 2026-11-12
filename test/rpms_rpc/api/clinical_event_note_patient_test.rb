# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/clinical_event"
require_relative "../orwpce_read_helpers"

# Issue #531: the note-keyed PCE reads refuse a note of another patient.
#
# On a positive note IEN, ORWPCE GET VISIT, ORWPCE HASVISIT and ORWPCE PCE4NOTE
# resolve everything from the TIU note and ignore DFN. visit_for_note,
# has_visit?, visit_status and pce_for_note therefore read the note's patient
# from the server first and send the ORWPCE RPC only when it is the DFN passed.
#
# The ownership read is TIU GET ALERT INFO (GETALRT^TIUSRVR, TIUSRVR.m:67-84),
# one parameter. It answers "note^DFN^tab" for a note on file with a patient,
# else -1. It is registered only in OR CPRS GUI CHART, so the mapping
# (:tiu_note_patient) binds that option.
#
# It fails closed. A reply that does not name the note asked for and a
# positive integer DFN is a refusal (reason :unknown), as is a server that
# does not serve the read. A DFN that is not the one passed is a refusal
# (reason :mismatch). Neither sends the ORWPCE RPC.
class ClinicalEventNotePatientTest < Minitest::Test
  include OrwpceReadHelpers

  NOTE = "1"
  OWNER = "4"
  OTHER = "990002"
  LOCATION = "6"
  VISIT_DATETIME = "3260312.09"
  VISIT_STRING = "6;3260312.09;A"

  # method => [ ORWPCE RPC, arguments after (note, dfn), note-0 arguments after (0, dfn) ]
  GUARDED = {
    visit_for_note: [ "ORWPCE GET VISIT", [ "" ], [ VISIT_STRING ] ],
    has_visit?: [ "ORWPCE HASVISIT", [ "", "" ], [ LOCATION, VISIT_DATETIME ] ],
    visit_status: [ "ORWPCE HASVISIT", [ "", "" ], [ LOCATION, VISIT_DATETIME ] ],
    pce_for_note: [ "ORWPCE PCE4NOTE", [ "" ], [ VISIT_STRING ] ]
  }.freeze

  # Replies to "whose note is 1?" that prove nothing. Each is tried as the
  # String and, where it is one line, as the one-element Array.
  UNKNOWN_REPLIES = [
    "-1", [ "-1" ],
    "", [ "" ], [], nil,
    "1", [ "1" ],
    "1^^903", [ "1^^903" ],
    "1^abc^903", [ "1^abc^903" ],
    "1^0^903", [ "1^0^903" ],
    "1^-4^903", [ "1^-4^903" ],
    "1^4.5^903", [ "1^4.5^903" ],
    "2^4^903", [ "2^4^903" ]
  ].freeze

  def teardown
    RpmsRpc.reset!
  end

  def clinical_event
    RpmsRpc::ClinicalEvent
  end

  def use(client)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def mismatch_error
    assert clinical_event.const_defined?(:NotePatientMismatchError, false),
           "spec(#531): define RpmsRpc::ClinicalEvent::NotePatientMismatchError"
    clinical_event.const_get(:NotePatientMismatchError, false)
  end

  # The call must raise the typed error with +reason+ and send no ORWPCE RPC.
  def assert_refused(reason, client, label, &call)
    error_class = mismatch_error
    error = begin
      call.call
      nil
    rescue error_class => e
      e
    end
    refute_nil error, "#{label}: expected NotePatientMismatchError (#{reason}), and nothing was raised"
    assert_equal reason, error.reason, label
    assert_empty orwpce_calls(client), "#{label}: no ORWPCE RPC may be sent for a refused note"
    error
  end

  # -- the mapping -----------------------------------------------------------

  def test_tiu_note_patient_mapping_is_tiu_get_alert_info
    assert RpmsRpc::DataMapper.respond_to?(:tiu_note_patient),
           "spec(#531): define DataMapper[:tiu_note_patient]"
    assert_equal "TIU GET ALERT INFO", RpmsRpc::DataMapper.tiu_note_patient.rpc_name
  end

  def test_tiu_note_patient_mapping_binds_or_cprs_gui_chart
    assert RpmsRpc::DataMapper.respond_to?(:tiu_note_patient),
           "spec(#531): define DataMapper[:tiu_note_patient]"
    assert_equal "OR CPRS GUI CHART", RpmsRpc::DataMapper.tiu_note_patient.bound_context
  end

  # -- the typed error -------------------------------------------------------

  def test_note_patient_mismatch_error_is_an_rpms_rpc_error
    assert_operator mismatch_error, :<, RpmsRpc::Error
  end

  def test_note_patient_mismatch_error_is_not_a_broker_rpc_error
    refute_operator mismatch_error, :<=, RpmsRpc::Client::RpcError
  end

  GUARDED.each do |method, (rpc, rest, zero_rest)|
    # -- another patient's note ----------------------------------------------

    define_method("test_#{method}_refuses_a_note_of_another_patient") do
      client = use RecordingClient.new(owner_reply: "#{NOTE}^#{OTHER}^903")

      assert_refused(:mismatch, client, method) { clinical_event.public_send(method, NOTE, OWNER, *rest) }
    end

    define_method("test_#{method}_refuses_a_note_of_another_patient_given_as_one_line") do
      client = use RecordingClient.new(owner_reply: [ "#{NOTE}^#{OTHER}^903" ])

      assert_refused(:mismatch, client, method) { clinical_event.public_send(method, NOTE, OWNER, *rest) }
    end

    define_method("test_#{method}_refuses_integer_arguments_for_a_note_of_another_patient") do
      client = use RecordingClient.new(owner_reply: "#{NOTE}^#{OWNER}^903")

      assert_refused(:mismatch, client, method) do
        clinical_event.public_send(method, NOTE.to_i, OTHER.to_i, *rest)
      end
    end

    define_method("test_#{method}_mismatch_message_does_not_name_the_notes_patient") do
      client = use RecordingClient.new(owner_reply: "#{NOTE}^#{OTHER}^903")
      error = assert_refused(:mismatch, client, method) do
        clinical_event.public_send(method, NOTE, OWNER, *rest)
      end

      refute_includes error.message, OTHER,
                      "the message must not carry the DFN of the patient the note belongs to"
    end

    define_method("test_#{method}_asks_for_the_notes_patient_before_refusing") do
      client = use RecordingClient.new(owner_reply: "#{NOTE}^#{OTHER}^903")
      assert_refused(:mismatch, client, method) { clinical_event.public_send(method, NOTE, OWNER, *rest) }

      assert_equal [ [ NOTE_PATIENT_RPC, NOTE ] ],
                   note_patient_calls(client).map { |name, *params| [ name, *params.map(&:to_s) ] }
    end

    # -- the note's patient cannot be determined -----------------------------

    define_method("test_#{method}_fails_closed_when_the_reply_does_not_prove_the_notes_patient") do
      UNKNOWN_REPLIES.each do |reply|
        client = use RecordingClient.new(owner_reply: reply)

        assert_refused(:unknown, client, "#{method} on reply #{reply.inspect}") do
          clinical_event.public_send(method, NOTE, OWNER, *rest)
        end
      end
    end

    define_method("test_#{method}_fails_closed_when_the_ownership_read_is_not_served") do
      client = use RecordingClient.new(served: IN_SCOPE_RPCS)

      assert_refused(:unknown, client, method) { clinical_event.public_send(method, NOTE, OWNER, *rest) }
    end

    [ RpmsRpc::Client::RpcError, RpmsRpc::Client::RpcNotAvailableError ].each do |broker_error|
      label = broker_error.name.split("::").last
      define_method("test_#{method}_lets_a_#{label}_from_the_ownership_read_through") do
        client = use RecordingClient.new(owner_reply: broker_error.new("synthetic broker refusal"))

        raised = assert_raises(RpmsRpc::Client::RpcError) do
          clinical_event.public_send(method, NOTE, OWNER, *rest)
        end
        assert_instance_of broker_error, raised
        assert_empty orwpce_calls(client), "no ORWPCE RPC may follow a refused ownership read"
      end
    end

    # -- the note's patient is the DFN passed --------------------------------

    define_method("test_#{method}_sends_todays_call_when_the_note_is_the_patients") do
      client = use RecordingClient.new(owner_reply: "#{NOTE}^#{OWNER}^903")
      clinical_event.public_send(method, NOTE, OWNER, *rest)

      assert_guarded_calls client, NOTE, [ rpc, NOTE, OWNER, *rest ]
    end

    define_method("test_#{method}_matches_a_one_line_array_reply") do
      client = use RecordingClient.new(owner_reply: [ "#{NOTE}^#{OWNER}^903" ])
      clinical_event.public_send(method, NOTE, OWNER, *rest)

      assert_guarded_calls client, NOTE, [ rpc, NOTE, OWNER, *rest ]
    end

    define_method("test_#{method}_matches_an_integer_dfn_and_note_against_the_reply") do
      client = use RecordingClient.new(owner_reply: "#{NOTE}^#{OWNER}^903")
      clinical_event.public_send(method, NOTE.to_i, OWNER.to_i, *rest)

      assert_guarded_calls client, NOTE, [ rpc, NOTE.to_i, OWNER.to_i, *rest ]
    end

    define_method("test_#{method}_reads_the_notes_patient_under_or_cprs_gui_chart") do
      client = use RecordingClient.new(owner_reply: "#{NOTE}^#{OWNER}^903")
      clinical_event.public_send(method, NOTE, OWNER, *rest)

      index = client.calls.index { |name, *| name == NOTE_PATIENT_RPC }
      refute_nil index, "#{method} must read the note's patient with #{NOTE_PATIENT_RPC}"
      assert_equal NOTE_PATIENT_CONTEXT, client.contexts[index],
                   "#{NOTE_PATIENT_RPC} is registered only in #{NOTE_PATIENT_CONTEXT}"
    end

    # -- argument validation still comes first -------------------------------

    define_method("test_#{method}_makes_no_ownership_read_for_invalid_arguments") do
      quiet = method == :has_visit? ? false : nil
      client = use RecordingClient.new(owner_reply: "#{NOTE}^#{OTHER}^903")

      (INVALID_NOTE_IDS.map { |bad| [ bad, OWNER ] } + INVALID_DFN_IDS.map { |bad| [ NOTE, bad ] }).each do |note, dfn|
        result = clinical_event.public_send(method, note, dfn, *rest)
        quiet.nil? ? assert_nil(result, [ note, dfn ].inspect) : assert_equal(quiet, result, [ note, dfn ].inspect)
      end
      assert_empty client.calls
    end

    # -- note 0: the server uses DFN, so there is no note to check -----------

    define_method("test_#{method}_makes_no_ownership_read_for_note_zero") do
      [ "0", 0 ].each do |zero|
        client = use RecordingClient.new(owner_reply: "#{NOTE}^#{OTHER}^903")
        clinical_event.public_send(method, zero, OWNER, *zero_rest)

        assert_equal [ [ rpc, zero, OWNER, *zero_rest ] ], client.calls
      end
    end
  end

  # -- malformed optional arguments on a positive note -------------------------

  def test_malformed_optional_arguments_make_no_ownership_read
    client = use RecordingClient.new(owner_reply: "#{NOTE}^#{OTHER}^903")

    assert_nil clinical_event.visit_for_note(NOTE, OWNER, ";;")
    assert_nil clinical_event.pce_for_note(NOTE, OWNER, ";;")
    refute clinical_event.has_visit?(NOTE, OWNER, "abc", "")
    assert_nil clinical_event.visit_status(NOTE, OWNER, "", "not-fileman")
    assert_empty client.calls
  end

  # -- note_visit_string: NOTEVSTR takes no DFN, so it is unscoped -------------

  def test_note_visit_string_makes_no_ownership_read
    client = use RecordingClient.new(owner_reply: "#{NOTE}^#{OTHER}^903")
    clinical_event.note_visit_string(NOTE)

    assert_equal [ [ "ORWPCE NOTEVSTR", NOTE ] ], client.calls
  end

  def test_note_visit_string_does_not_need_the_ownership_read_served
    client = use RecordingClient.new(served: IN_SCOPE_RPCS)
    clinical_event.note_visit_string(NOTE)

    assert_equal [ [ "ORWPCE NOTEVSTR", NOTE ] ], client.calls
  end

  # -- through MockClient ------------------------------------------------------

  def seed_pce(mock)
    mock.seed_scalar(:pce_get_visit, NOTE, "4")
    mock.seed_scalar(:pce_has_visit, NOTE, "0")
    mock.seed_scalar(:pce_for_note, NOTE, "HDR^0^^3;3260902.0255;A^4^1")
  end

  def orwpce_sent
    RpmsRpc.client.received_calls.map { |c| c[:rpc] } & NOTE_KEYED_RPCS
  end

  def assert_mock_refused(reason, method, dfn)
    error_class = mismatch_error
    error = begin
      clinical_event.public_send(method, NOTE, dfn)
      nil
    rescue error_class => e
      e
    end
    refute_nil error, "#{method}: seeded PCE data came back for a refused note"
    assert_equal reason, error.reason, method
    assert_empty orwpce_sent, method
  end

  def test_mock_returns_seeded_pce_data_for_the_notes_patient
    RpmsRpc.mock! do |m|
      seed_pce(m)
      seed_note_owner(m, NOTE, OWNER)
    end

    assert_equal 4, clinical_event.visit_for_note(NOTE, OWNER)
    assert clinical_event.has_visit?(NOTE, OWNER)
    assert_equal :stand_alone, clinical_event.visit_status(NOTE, OWNER)
    assert_equal "3;3260902.0255;A", clinical_event.pce_for_note(NOTE, OWNER).dig(:header, :visit_string)
  end

  def test_mock_reads_the_notes_patient_under_or_cprs_gui_chart
    RpmsRpc.mock! do |m|
      seed_pce(m)
      seed_note_owner(m, NOTE, OWNER)
    end
    RpmsRpc.client.create_context("CIAV VUECENTRIC")
    clinical_event.visit_for_note(NOTE, OWNER)

    owner_calls = RpmsRpc.client.received_calls.select { |c| c[:rpc] == NOTE_PATIENT_RPC }
    assert_equal [ NOTE_PATIENT_CONTEXT ], owner_calls.map { |c| c[:context] }
    assert_equal "CIAV VUECENTRIC", RpmsRpc.client.current_context,
                 "the caller's context must be restored after the ownership read"
  end

  def test_mock_returns_no_seeded_pce_data_for_another_patient
    GUARDED.each_key do |method|
      RpmsRpc.mock! do |m|
        seed_pce(m)
        seed_note_owner(m, NOTE, OWNER)
      end

      assert_mock_refused(:mismatch, method, OTHER)
    end
  end

  def test_mock_without_a_seeded_note_patient_refuses
    GUARDED.each_key do |method|
      RpmsRpc.mock! { |m| seed_pce(m) }

      assert_mock_refused(:unknown, method, OWNER)
    end
  end
end
