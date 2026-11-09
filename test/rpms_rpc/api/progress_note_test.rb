# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/progress_note"
require_relative "../captured_replies"

# Issue #219: the TIU note surface sends the actuals each routine declares
# and reads the reply the way the routine writes it.
#
# Routine lines are the FOIA source, Text Integration Utility/Routines;
# formal lists are the pinned registry (rpms-diffs rpcs/registry.tsv). The
# first formal is the return variable the broker supplies; the gem's P1
# fills the second.
#
# Replies are the pinned build's, captured on a note filed as PROFILE,MD on
# seed patient DFN 4, title 248, visit 4 (test/fixtures/captured_replies/
# progress-note.yml), replayed through CiaClient.
class ProgressNoteTest < Minitest::Test
  SLUG      = "progress-note"
  DFN       = "4"
  VISIT_IEN = "4"
  TITLE_IEN = "248"

  def self.note_ien = CapturedReplies.file(SLUG).fetch("captures").find { |c| c["name"] == "lock" }.fetch("inputs").first
  NOTE_IEN = note_ien

  # Broker stub that returns one canned raw response for every RPC —
  # for exercising nil/garbage response paths no capture holds.
  class RawResponseClient
    def initialize(response) = @response = response
    def call_rpc(*) = @response
  end

  # The same, past update_text's TIU AUTHORIZATION (#614): that call is
  # allowed, so the canned response reaches TIU SET DOCUMENT TEXT.
  class AuthorizedRawResponseClient < RawResponseClient
    def call_rpc(rpc, *) = rpc == "TIU AUTHORIZATION" ? "1" : @response
  end

  def teardown
    RpmsRpc.reset!
  end

  def stub_broker_response(response)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = RawResponseClient.new(response) }
  end

  # A CiaClient answering each RPC with the named captures, in order.
  def replay(script)
    @client = CapturedReplies::ReplayCiaClient.new(script.transform_values { |names| Array(names).map { |n| CapturedReplies.raw(SLUG, n) } })
    RpmsRpc.configure { |cfg| cfg.client = @client }
    @client
  end

  def params_sent_to(rpc)
    call = @client.calls.find { |c| c[:rpc] == rpc }
    refute_nil call, "#{rpc} was not called"
    call[:params]
  end

  # -- TIU LOCK RECORD / TIU UNLOCK RECORD (AC 1, 2) -------------------------

  # LOCK(ERR,TIUDA) (TIUSRVP.m:210): one actual, the note.
  def test_lock_sends_only_the_note_ien
    replay("TIU LOCK RECORD" => "lock")

    RpmsRpc::ProgressNote.lock(NOTE_IEN)
    assert_equal [ NOTE_IEN ], params_sent_to("TIU LOCK RECORD")
  end

  # ERR=0 when the lock is granted (TIUSRVP.m:211).
  def test_lock_is_true_when_the_routine_answers_zero
    replay("TIU LOCK RECORD" => "lock")

    assert_equal true, RpmsRpc::ProgressNote.lock(NOTE_IEN)
  end

  # ERR="1^ Another session has this record locked." when it is not
  # (TIUSRVP.m:212). The old :boolean read this "1" as true: a lock that
  # FAILED was reported as held.
  def test_lock_is_false_when_another_session_holds_the_record
    replay("TIU LOCK RECORD" => "lock_held_elsewhere")

    assert_equal false, RpmsRpc::ProgressNote.lock(NOTE_IEN)
  end

  # UNLOCK(ERR,TIUDA) (TIUSRVP.m:214-215): one actual; always ERR=0, which
  # the old :boolean read as false.
  def test_unlock_sends_only_the_note_ien_and_is_true_on_zero
    replay("TIU UNLOCK RECORD" => "unlock")

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
    replay("TIU CREATE RECORD" => "create")

    RpmsRpc::ProgressNote.create(DFN, VISIT_IEN, TITLE_IEN)
    assert_equal [ DFN, TITLE_IEN, "", "", VISIT_IEN ], params_sent_to("TIU CREATE RECORD")
  end

  # SUCCESS=+TIUDA (TIUSRVP.m:61).
  def test_create_returns_new_note_ien_on_success
    replay("TIU CREATE RECORD" => "create")
    ien = CapturedReplies.raw(SLUG, "create").byteslice(2..)

    result = RpmsRpc::ProgressNote.create(DFN, VISIT_IEN, TITLE_IEN)
    assert_equal({ success: true, ien: Integer(ien), raw: ien }, result)
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
    replay("TIU AUTHORIZATION" => "authorize_edit")

    RpmsRpc::ProgressNote.authorize(NOTE_IEN)
    assert_equal [ NOTE_IEN, "EDIT RECORD" ], params_sent_to("TIU AUTHORIZATION")
  end

  def test_authorize_sends_the_named_action
    replay("TIU AUTHORIZATION" => "authorize_signature")

    RpmsRpc::ProgressNote.authorize(NOTE_IEN, action: "SIGNATURE")
    assert_equal [ NOTE_IEN, "SIGNATURE" ], params_sent_to("TIU AUTHORIZATION")
  end

  # TIUY=$$CANDO^TIULP: 1 when allowed (TIUSRVA.m:30), "0^reason" when not
  # (TIUSRVA.m:23, 26, 29). The refusal is the build's answer to another
  # user asking to edit the author's unsigned note.
  def test_authorize_reads_one_as_allowed_and_zero_caret_reason_as_refused
    replay("TIU AUTHORIZATION" => %w[authorize_edit authorize_edit_other_user])
    assert_equal true, RpmsRpc::ProgressNote.authorize(NOTE_IEN)
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
    replay("TIU DOCUMENTS BY CONTEXT" => "list_all_signed")

    RpmsRpc::ProgressNote.list(DFN)
    assert_equal [ "3", "1", DFN ], params_sent_to("TIU DOCUMENTS BY CONTEXT")
  end

  # The context codes TIUSRVLO.m:19-23 documents.
  def test_list_passes_each_context_code
    expected = { all_signed: "1", unsigned: "2", uncosigned: "3",
                 signed_by_author: "4", signed_by_date_range: "5" }
    expected.each do |ctx, code|
      replay("TIU DOCUMENTS BY CONTEXT" => "list_all_signed")
      RpmsRpc::ProgressNote.list(DFN, context: ctx)
      assert_equal code, params_sent_to("TIU DOCUMENTS BY CONTEXT")[1], "context #{ctx} should map to #{code}"
    end
  end

  # PERSON narrows contexts 2-4 to one author or cosigner; EARLY/LATE bound
  # context 5 (TIUSRVLO.m:25-27, 38-42). They follow DFN in that order.
  def test_list_sends_early_late_and_person_after_dfn
    replay("TIU DOCUMENTS BY CONTEXT" => "list_by_date_range")
    refute_empty RpmsRpc::ProgressNote.list(DFN, context: :signed_by_date_range, early: "3260901", late: "3261231", person: "206")
    assert_equal [ "3", "5", DFN, "3260901", "3261231", "206" ], params_sent_to("TIU DOCUMENTS BY CONTEXT")
  end

  def test_list_raises_on_unknown_context
    assert_raises(ArgumentError) { RpmsRpc::ProgressNote.list(DFN, context: :by_visit) }
  end

  # Each row is DA_U_$$RESOLVE(DA) (TIUSRVLO.m:94); RESOLVE builds
  # DOC^EDT^PT^AUT^LOC^STATUS^TIUADT^TIUDDT^... (TIUSRVLO.m:197), with AUT
  # as DUZ;SIGNATURE NAME;NAME (TIUSRVLO.m:195).
  def test_list_parses_each_row_by_the_resolve_layout
    replay("TIU DOCUMENTS BY CONTEXT" => "list_unsigned")

    doc = RpmsRpc::ProgressNote.list(DFN, context: :unsigned).find { |d| d[:ien] == Integer(NOTE_IEN) }
    refute_nil doc, "the note filed in setup is listed as unsigned"
    assert_equal "Progress Note", doc[:title]
    assert_equal "DEMO, PATIENT O (D0101)", doc[:patient]
    assert_equal "206", doc[:author_duz]
    assert_equal "PROFILE,MD", doc[:author_name]
    assert_equal "unsigned", doc[:status]
    assert_equal "Visit: 09/02/26", doc[:visit]
    assert_kind_of Time, doc[:datetime]

    replay("TIU DOCUMENTS BY CONTEXT" => "list_all_signed")
    signed = RpmsRpc::ProgressNote.list(DFN).first
    assert_equal({ ien: 5, title: "TELEPHONE NOTE", datetime: Time.new(2026, 9, 4, 23, 44, 40), location: "CHART REVIEW",
                   status: "completed", author_duz: "4", author_name: "MANAGER,SYSTEM" },
                 signed.slice(:ien, :title, :datetime, :location, :status, :author_duz, :author_name))
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
    replay("TIU GET RECORD TEXT" => "get_text")

    text = RpmsRpc::ProgressNote.fetch_text(NOTE_IEN)
    assert_match(/STATUS: UNSIGNED/, text)
    assert_match(/^S: cough\nO: afebrile$/, text, "the body the author set")
    assert_equal [ NOTE_IEN ], params_sent_to("TIU GET RECORD TEXT")
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
    replay("TIU AUTHORIZATION" => "authorize_edit", "TIU SET DOCUMENT TEXT" => "set_text") # CANDO^TIUSRVA first (#614)

    RpmsRpc::ProgressNote.update_text(NOTE_IEN, "S: cough\nO: afebrile")
    assert_equal [ NOTE_IEN, { "HDR" => "1^1", [ "TEXT", 1, 0 ] => "S: cough", [ "TEXT", 2, 0 ] => "O: afebrile" } ],
                 params_sent_to("TIU SET DOCUMENT TEXT")
  end

  # TIUY=TIUDA_U_PAGE_U_PAGES acknowledges the page (TIUSRVPT.m:38).
  def test_update_text_succeeds_on_the_page_acknowledgement
    replay("TIU AUTHORIZATION" => "authorize_edit", "TIU SET DOCUMENT TEXT" => "set_text") # CANDO^TIUSRVA first (#614)

    assert_equal({ success: true, raw: "#{NOTE_IEN}^1^1" }, RpmsRpc::ProgressNote.update_text(NOTE_IEN, "S: cough\nO: afebrile"))
  end

  # TIUY="0^0^0^"_message on failure (TIUSRVPT.m:10, 14). The old check
  # called a bare "0" success.
  def test_update_text_fails_on_a_zero_reply
    # The build's reply when TIUX carries no HDR node: what the old flat frame got.
    replay("TIU AUTHORIZATION" => "authorize_edit", "TIU SET DOCUMENT TEXT" => "set_text_flat")

    result = RpmsRpc::ProgressNote.update_text(NOTE_IEN, "x")
    refute result[:success]
    assert_equal "0^0^0^Invalid text block header", result[:raw]
  end

  def test_update_text_nil_broker_response_does_not_raise
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = AuthorizedRawResponseClient.new(nil) }

    assert_equal({ success: false, raw: nil }, RpmsRpc::ProgressNote.update_text(NOTE_IEN, "x"),
                 "a nil TIU SET DOCUMENT TEXT reply is a failure, not a raise")
  end

  def test_update_text_nil_authorization_reply_sends_no_text
    stub_broker_response(nil)

    result = RpmsRpc::ProgressNote.update_text(NOTE_IEN, "x")
    refute result[:success]
    assert_nil result[:raw]
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
    replay({})
    refute RpmsRpc::ProgressNote.create(nil, VISIT_IEN, TITLE_IEN)[:success]
    assert_equal [], RpmsRpc::ProgressNote.list(nil)
    assert_nil RpmsRpc::ProgressNote.fetch_text("0")
    refute RpmsRpc::ProgressNote.authorize(nil)
    refute RpmsRpc::ProgressNote.lock(nil)
    refute RpmsRpc::ProgressNote.unlock("")
    refute RpmsRpc::ProgressNote.update_text(nil, "x")[:success]
    refute RpmsRpc::ProgressNote.update_text(NOTE_IEN, nil)[:success]
    assert_empty @client.calls
  end
end
