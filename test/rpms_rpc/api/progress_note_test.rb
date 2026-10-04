# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/progress_note"

# Issue #219: the TIU note surface sends the actuals each routine declares
# and reads the reply the way the routine writes it.
#
# Routine lines are the FOIA source, Text Integration Utility/Routines;
# formal lists are the pinned registry (rpms-diffs rpcs/registry.tsv). The
# first formal is the return variable the broker supplies; the gem's P1
# fills the second. MockClient keys a seeded reply by the first actual.
class ProgressNoteTest < Minitest::Test
  DFN       = "8791"
  VISIT_IEN = "2090060"
  TITLE_IEN = "3001"
  NOTE_IEN  = "5001"

  # LOCK^TIUSRVP's failure text, verbatim (TIUSRVP.m:212).
  LOCKED_ELSEWHERE = "1^ Another session has this record locked."

  # Broker stub that returns one canned raw response for every RPC —
  # for exercising nil/garbage response paths MockClient can't produce.
  class RawResponseClient
    def initialize(response) = @response = response
    def supports?(*) = true
    def call_rpc(*) = @response
  end

  def teardown
    RpmsRpc.reset!
  end

  def stub_broker_response(response)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = RawResponseClient.new(response) }
  end

  def params_sent_to(rpc)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == rpc }
    refute_nil call, "#{rpc} was not called"
    call[:params]
  end

  # -- TIU LOCK RECORD / TIU UNLOCK RECORD (AC 1, 2) -------------------------

  # LOCK(ERR,TIUDA) (TIUSRVP.m:210): one actual, the note.
  def test_lock_sends_only_the_note_ien
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_lock_record, NOTE_IEN, "0") }

    RpmsRpc::ProgressNote.lock(NOTE_IEN)
    assert_equal [ NOTE_IEN ], params_sent_to("TIU LOCK RECORD")
  end

  # ERR=0 when the lock is granted (TIUSRVP.m:211).
  def test_lock_is_true_when_the_routine_answers_zero
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_lock_record, NOTE_IEN, "0") }

    assert_equal true, RpmsRpc::ProgressNote.lock(NOTE_IEN)
  end

  # ERR="1^ Another session has this record locked." when it is not
  # (TIUSRVP.m:212). The old :boolean read this "1" as true: a lock that
  # FAILED was reported as held.
  def test_lock_is_false_when_another_session_holds_the_record
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_lock_record, NOTE_IEN, LOCKED_ELSEWHERE) }

    assert_equal false, RpmsRpc::ProgressNote.lock(NOTE_IEN)
  end

  # UNLOCK(ERR,TIUDA) (TIUSRVP.m:214-215): one actual; always ERR=0, which
  # the old :boolean read as false.
  def test_unlock_sends_only_the_note_ien_and_is_true_on_zero
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_unlock_record, NOTE_IEN, "0") }

    assert_equal true, RpmsRpc::ProgressNote.unlock(NOTE_IEN)
    assert_equal [ NOTE_IEN ], params_sent_to("TIU UNLOCK RECORD")
  end

  def test_lock_and_unlock_no_longer_take_a_user
    assert_raises(ArgumentError) { RpmsRpc::ProgressNote.lock(NOTE_IEN, "301") }
    assert_raises(ArgumentError) { RpmsRpc::ProgressNote.unlock(NOTE_IEN, "301") }
  end

  # -- TIU CREATE RECORD (AC 3) ----------------------------------------------

  # MAKE(SUCCESS,DFN,TITLE,VDT,VLOC,VSIT,TIUX,VSTR,SUPPRESS,NOASF)
  # (TIUSRVP.m:7). The visit goes in VSIT, from which MAKE builds the visit
  # string and date (TIUSRVP.m:24-31); VDT and VLOC go empty. The old frame
  # put the visit IEN in TITLE and the title IEN in VDT.
  def test_create_frames_dfn_title_vdt_vloc_vsit
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_create_record, DFN, "5001") }

    RpmsRpc::ProgressNote.create(DFN, VISIT_IEN, TITLE_IEN)
    assert_equal [ DFN, TITLE_IEN, "", "", VISIT_IEN ], params_sent_to("TIU CREATE RECORD")
  end

  # SUCCESS=+TIUDA (TIUSRVP.m:61).
  def test_create_returns_new_note_ien_on_success
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_create_record, DFN, "5001") }

    result = RpmsRpc::ProgressNote.create(DFN, VISIT_IEN, TITLE_IEN)
    assert_equal({ success: true, ien: 5001, raw: "5001" }, result)
  end

  # SUCCESS="0^"_message (TIUSRVP.m:58, 60).
  def test_create_returns_failure_on_a_zero_caret_message
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_create_record, DFN, "0^Patient & Visit required.") }

    result = RpmsRpc::ProgressNote.create(DFN, VISIT_IEN, TITLE_IEN)
    refute result[:success]
    assert_equal "0^Patient & Visit required.", result[:raw]
  end

  def test_create_nil_broker_response_does_not_raise
    stub_broker_response(nil)

    result = RpmsRpc::ProgressNote.create(DFN, VISIT_IEN, TITLE_IEN)
    assert_equal({ success: false, ien: nil, raw: nil }, result)
  end

  # -- TIU AUTHORIZATION (AC 4) ----------------------------------------------

  # CANDO(TIUY,TIUDA,TIUACT) (TIUSRVA.m:20): the second actual is the ACTION
  # string the routine compares (TIUSRVA.m:23-24). The old frame sent the
  # user's DUZ there.
  def test_authorize_frames_note_and_action
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_authorization, NOTE_IEN, "1") }

    RpmsRpc::ProgressNote.authorize(NOTE_IEN)
    assert_equal [ NOTE_IEN, "EDIT RECORD" ], params_sent_to("TIU AUTHORIZATION")
  end

  def test_authorize_sends_the_named_action
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_authorization, NOTE_IEN, "1") }

    RpmsRpc::ProgressNote.authorize(NOTE_IEN, action: "SIGNATURE")
    assert_equal [ NOTE_IEN, "SIGNATURE" ], params_sent_to("TIU AUTHORIZATION")
  end

  # TIUY=$$CANDO^TIULP: 1 when allowed (TIUSRVA.m:30), "0^reason" when not
  # (TIUSRVA.m:23, 26, 29).
  def test_authorize_reads_one_as_allowed_and_zero_caret_reason_as_refused
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_authorization, NOTE_IEN, "1") }
    assert_equal true, RpmsRpc::ProgressNote.authorize(NOTE_IEN)

    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_authorization, NOTE_IEN, "0^ Another session is editing this entry.") }
    assert_equal false, RpmsRpc::ProgressNote.authorize(NOTE_IEN)
  end

  def test_authorize_no_longer_takes_a_user
    assert_raises(ArgumentError) { RpmsRpc::ProgressNote.authorize(NOTE_IEN, "301") }
  end

  # -- TIU DOCUMENTS BY CONTEXT (AC 5) ---------------------------------------

  # CONTEXT(TIUY,CLASS,CONTEXT,DFN,...) (TIUSRVLO.m:16). CLASS 3 is the
  # class NOTES^TIUSRVLO lists progress notes under (TIUSRVLO.m:8). The old
  # frame sent (dfn, code) into CLASS and CONTEXT, so DFN was empty and the
  # list always came back empty.
  def test_list_frames_class_context_dfn
    RpmsRpc.mock!

    RpmsRpc::ProgressNote.list(DFN)
    assert_equal [ "3", "1", DFN ], params_sent_to("TIU DOCUMENTS BY CONTEXT")
  end

  # The context codes TIUSRVLO.m:19-23 documents.
  def test_list_passes_each_context_code
    expected = { all_signed: "1", unsigned: "2", uncosigned: "3",
                 signed_by_author: "4", signed_by_date_range: "5" }
    expected.each do |ctx, code|
      RpmsRpc.mock!
      RpmsRpc::ProgressNote.list(DFN, context: ctx)
      assert_equal code, params_sent_to("TIU DOCUMENTS BY CONTEXT")[1], "context #{ctx} should map to #{code}"
    end
  end

  # PERSON narrows contexts 2-4 to one author or cosigner; EARLY/LATE bound
  # context 5 (TIUSRVLO.m:25-27, 38-42). They follow DFN in that order.
  def test_list_sends_early_late_and_person_after_dfn
    RpmsRpc.mock!
    RpmsRpc::ProgressNote.list(DFN, context: :signed_by_date_range, early: "3260901", late: "3261002", person: "301")
    assert_equal [ "3", "5", DFN, "3260901", "3261002", "301" ], params_sent_to("TIU DOCUMENTS BY CONTEXT")
  end

  def test_list_raises_on_unknown_context
    assert_raises(ArgumentError) { RpmsRpc::ProgressNote.list(DFN, context: :by_visit) }
  end

  # Each row is DA_U_$$RESOLVE(DA) (TIUSRVLO.m:94); RESOLVE builds
  # DOC^EDT^PT^AUT^LOC^STATUS^TIUADT^TIUDDT^... (TIUSRVLO.m:197), with AUT
  # as DUZ;SIGNATURE NAME;NAME (TIUSRVLO.m:195).
  ROW = "5001^PROGRESS NOTE^3261002.0930^DEMO,PATIENT (D1234)^" \
        "301;PROVIDER,TEST;PROVIDER,TEST^GENERAL^unsigned^Visit: 10/02/26^^0^0^^^1^"

  def test_list_parses_each_row_by_the_resolve_layout
    RpmsRpc.mock! { |m| m.seed_raw_lines(:tiu_documents_by_context, "3", [ ROW ]) }

    doc = RpmsRpc::ProgressNote.list(DFN).first
    assert_equal 5001, doc[:ien]
    assert_equal "PROGRESS NOTE", doc[:title]
    assert_equal Time.new(2026, 10, 2, 9, 30), doc[:datetime]
    assert_equal "DEMO,PATIENT (D1234)", doc[:patient]
    assert_equal "301", doc[:author_duz]
    assert_equal "PROVIDER,TEST", doc[:author_name]
    assert_equal "GENERAL", doc[:location]
    assert_equal "unsigned", doc[:status]
    assert_equal "Visit: 10/02/26", doc[:visit]
  end

  def test_list_scalar_error_response_returns_empty_array
    # A broker returning a bare error string where a list is expected
    # must not crash and must yield NO rows.
    stub_broker_response("-1^NO DOCUMENTS FOUND")

    assert_equal [], RpmsRpc::ProgressNote.list(DFN)
  end

  def test_list_nil_broker_response_returns_empty_array
    stub_broker_response(nil)

    assert_equal [], RpmsRpc::ProgressNote.list(DFN)
  end

  # -- TIU GET RECORD TEXT (unchanged) ---------------------------------------

  def test_fetch_text_returns_note_body
    RpmsRpc.mock! do |m|
      m.seed_text(:tiu_get_record_text, NOTE_IEN, "S: chief complaint\nO: findings\n")
    end

    assert_match(/chief complaint/, RpmsRpc::ProgressNote.fetch_text(NOTE_IEN))
  end

  def test_fetch_text_nil_broker_response_returns_nil
    stub_broker_response(nil)

    assert_nil RpmsRpc::ProgressNote.fetch_text(NOTE_IEN)
  end

  # -- TIU SET DOCUMENT TEXT (AC 6) ------------------------------------------

  # SETTEXT(TIUY,TIUDA,TIUX,SUPPRESS) (TIUSRVPT.m:7) reads TIUX as a LIST:
  # PAGE^PAGES from TIUX("HDR") (TIUSRVPT.m:12) and the body from
  # TIUX("TEXT",n,0) (TIUSRVPT.m:18). A flat string has no "HDR" node, so
  # every update failed "Invalid text block header" (TIUSRVPT.m:13-14).
  def test_update_text_sends_tiux_as_a_header_and_text_list
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_set_document_text, NOTE_IEN, "#{NOTE_IEN}^1^1") }

    RpmsRpc::ProgressNote.update_text(NOTE_IEN, "S: cough\nO: afebrile")
    assert_equal [ NOTE_IEN, { "HDR" => "1^1", [ "TEXT", 1, 0 ] => "S: cough", [ "TEXT", 2, 0 ] => "O: afebrile" } ],
                 params_sent_to("TIU SET DOCUMENT TEXT")
  end

  # TIUY=TIUDA_U_PAGE_U_PAGES acknowledges the page (TIUSRVPT.m:38).
  def test_update_text_succeeds_on_the_page_acknowledgement
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_set_document_text, NOTE_IEN, "#{NOTE_IEN}^1^1") }

    assert_equal({ success: true, raw: "#{NOTE_IEN}^1^1" }, RpmsRpc::ProgressNote.update_text(NOTE_IEN, "x"))
  end

  # TIUY="0^0^0^"_message on failure (TIUSRVPT.m:10, 14). The old check
  # called a bare "0" success.
  def test_update_text_fails_on_a_zero_reply
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_set_document_text, NOTE_IEN, "0^0^0^Invalid text block header") }

    result = RpmsRpc::ProgressNote.update_text(NOTE_IEN, "x")
    refute result[:success]
    assert_equal "0^0^0^Invalid text block header", result[:raw]
  end

  def test_update_text_nil_broker_response_does_not_raise
    stub_broker_response(nil)

    assert_equal({ success: false, raw: nil }, RpmsRpc::ProgressNote.update_text(NOTE_IEN, "x"))
  end

  # -- guards ----------------------------------------------------------------

  def test_garbage_response_reads_as_refused
    stub_broker_response("-1^SOMETHING WENT WRONG")

    refute RpmsRpc::ProgressNote.authorize(NOTE_IEN)
    refute RpmsRpc::ProgressNote.lock(NOTE_IEN)
    refute RpmsRpc::ProgressNote.unlock(NOTE_IEN)
    refute RpmsRpc::ProgressNote.update_text(NOTE_IEN, "x")[:success]
  end

  def test_blank_args_return_safe_defaults_without_calling
    RpmsRpc.mock!
    refute RpmsRpc::ProgressNote.create(nil, VISIT_IEN, TITLE_IEN)[:success]
    assert_equal [], RpmsRpc::ProgressNote.list(nil)
    assert_nil RpmsRpc::ProgressNote.fetch_text("0")
    refute RpmsRpc::ProgressNote.authorize(nil)
    refute RpmsRpc::ProgressNote.lock(nil)
    refute RpmsRpc::ProgressNote.unlock("")
    refute RpmsRpc::ProgressNote.update_text(nil, "x")[:success]
    refute RpmsRpc::ProgressNote.update_text(NOTE_IEN, nil)[:success]
    assert_empty RpmsRpc.client.received_calls
  end
end
