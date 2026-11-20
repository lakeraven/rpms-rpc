# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require "rpms_rpc/mappings"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/retry_safety"
require_relative "amhg_replay"

# AMHG SAVE PROGRESS NOTES: PN^AMHGSVF (AMHGSVF.m:196-219), CCPD/PN/CMT^AMHGEVF.
#
# The guard and refusal cases, read from the conversations the pinned build
# had with BehavioralHealth.save_progress_note
# (test/fixtures/captured_replies/amhg-save-progress-notes.yml), on one BH
# visit for synthetic patient DFN 990034: a save with a multi-line note, a
# two-line comment, a placement disposition and referred-to; a save with an
# empty comment; and the refusals the build's replies lead to (the visit
# names another patient, a placement disposition inactive or not on file).
# The round trip itself is proven by
# test/live/behavioral_health_save_progress_note_live_test.rb (rpms-rpc#622, option b).
class BehavioralHealthSaveProgressNoteTest < Minitest::Test
  BH = RpmsRpc::BehavioralHealth
  SLUG = "amhg-save-progress-notes"
  RPC = "AMHG SAVE PROGRESS NOTES"
  RPC_SOAP = "AMHG GET VISIT SOAP"
  RPC_COMM = "AMHG GET VISIT COMM APP"
  GETS = "DDR GETS ENTRY DATA"
  PLACEMENT_FILE = "9002013.6"

  ROOT = File.expand_path("../../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  def self.wire(flow) = CapturedReplies.flow(SLUG, flow).find { |c| c["rpc"] == RPC }.fetch("inputs").first
  def self.gets(flow, at) = CapturedReplies.flow(SLUG, flow).select { |c| c["rpc"] == GETS }.fetch(at).fetch("inputs").first

  _, RECORD_IEN, CHIEF_COMPLAINT, NOTE, COMMENT, PLACEMENT, REFERRED_TO, PATIENT = wire("save").split("|", -1)
  EMPTY_COMMENT_NOTE = wire("save_empty_comment").split("|", -1)[3]
  INACTIVE_PLACEMENT = gets("placement_inactive", 1).fetch("IENS").delete_suffix(",")
  OTHER_PATIENT = "990035"
  NOT_ON_FILE = "999999"

  FULL_KWARGS = {
    record_ien: RECORD_IEN, patient: PATIENT, chief_complaint: CHIEF_COMPLAINT, note: NOTE, comment: COMMENT,
    placement_disposition: PLACEMENT, referred_to: REFERRED_TO
  }.freeze
  EMPTY_COMMENT_KWARGS = FULL_KWARGS.merge(note: EMPTY_COMMENT_NOTE, comment: "").freeze
  KWARG_KEYS = FULL_KWARGS.keys.freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow = "save", **opts) = @client = AmhgReplay.flow(SLUG, flow, **opts)

  # A flow with one RPC's reply at index answered by another capture's reply.
  def replay_with(rpc, index, reply, flow: "save", **opts)
    script = CapturedReplies.flow_script(SLUG, flow)
    script[rpc][index] = reply
    @client = AmhgReplay.use(AmhgReplay::Client.new(script, **opts))
  end

  def flow_raw(flow, rpc, index) = CapturedReplies.flow_script(SLUG, flow).fetch(rpc).fetch(index)
  def sent = @client.calls.select { |c| c[:rpc].is_a?(String) }.map { |c| [ c[:rpc], c[:params] ] }
  def amhg_calls = @client.calls.select { |c| c[:rpc] == RPC }

  def after_save
    calls = @client.calls.select { |c| c[:rpc].is_a?(String) }
    calls.drop(calls.index { |c| c[:rpc] == RPC } + 1)
  end

  def assert_refused_before_amhg(pattern, flow, **kwargs)
    replay(flow)
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**kwargs) }
    assert_match pattern, err.message
    assert_empty amhg_calls, "nothing may reach #{RPC}"
    assert_equal CapturedReplies.flow_calls(SLUG, flow), sent
    err
  end

  def assert_input_validation_refusal(label = nil, **kwargs)
    @client = AmhgReplay.silent
    assert_raises(BH::SaveError, label.to_s) { BH.save_progress_note(**kwargs) }
    assert_empty @client.calls, "input validation must refuse before any RPC (#{label})"
  end

  def assert_outcome_unknown(err)
    assert_match(/may have been|outcome (is )?unknown/i, err.message)
    [ PATIENT, CHIEF_COMPLAINT, COMMENT.lines.first.chomp, REFERRED_TO ].each { |v| refute_includes err.message, v }
  end

  # --- the captured saves -----------------------------------------------------

  def test_the_captured_save_returns_the_record_ien
    replay

    assert_equal RECORD_IEN, BH.save_progress_note(**FULL_KWARGS)
  end

  # The visit pre-read (.08, 1110, 1112), the placement read, the eight-piece
  # write with the note's LFs kept, the scalar read-back, then the SOAP and
  # comment read-backs: each request is the one the build answered.
  def test_each_request_is_the_one_the_build_answered
    replay
    BH.save_progress_note(**FULL_KWARGS)

    assert_equal CapturedReplies.flow_calls(SLUG, "save"), sent
    assert_equal 8, amhg_calls.first[:params].first.split("|", -1).length
    assert_includes amhg_calls.first[:params].first, NOTE
  end

  # An empty comment is sent blank and not read back: the build leaves the
  # stored comment as it was (WP^DIE error 305).
  def test_an_empty_comment_is_sent_blank_and_not_read_back
    replay("save_empty_comment")

    assert_equal RECORD_IEN, BH.save_progress_note(**EMPTY_COMMENT_KWARGS)
    assert_equal CapturedReplies.flow_calls(SLUG, "save_empty_comment"), sent
    refute_includes @client.rpcs_called, RPC_COMM
  end

  def test_the_pre_reads_run_before_the_write_under_the_fileman_context
    replay
    BH.save_progress_note(**FULL_KWARGS)

    calls = @client.calls.select { |c| c[:rpc].is_a?(String) }
    before = calls.take(calls.index { |c| c[:rpc] == RPC })
    assert_equal [ GETS, GETS ], before.map { |c| c[:rpc] }
    assert_equal PLACEMENT_FILE, before.last[:params].first["FILE"]
    before.each { |c| assert_equal AmhgReplay::FILEMAN_CONTEXT, c[:context] }
  end

  # The write and the SOAP and comment reads are AMHG RPCs under AMHGRPC; the
  # scalar read-back is DDR under the FileMan context; the caller's context
  # is restored.
  def test_amhg_calls_run_under_amhgrpc_and_ddr_calls_under_the_fileman_context
    replay
    BH.save_progress_note(**FULL_KWARGS)

    @client.calls.select { |c| c[:rpc].is_a?(String) }.each do |c|
      want = c[:rpc].start_with?("AMHG ") ? "AMHGRPC" : AmhgReplay::FILEMAN_CONTEXT
      assert_equal want, c[:context], c[:rpc]
    end
    assert_equal AmhgReplay::FILEMAN_CONTEXT, @client.current_context
  end

  def test_a_session_with_no_context_rebinds_the_fileman_context_for_the_ddr_read_back
    replay(context: nil)
    capture_io { BH.save_progress_note(**FULL_KWARGS) }

    assert_equal AmhgReplay::FILEMAN_CONTEXT, after_save.find { |c| c[:rpc] == GETS }[:context]
    assert_equal "AMHGRPC", after_save.find { |c| c[:rpc] == RPC_SOAP }[:context]
  end

  # --- refusals the build's replies lead to -----------------------------------

  def test_a_visit_of_another_patient_is_refused_after_the_pre_read
    assert_refused_before_amhg(/patient/i, "other_patient", **FULL_KWARGS, patient: OTHER_PATIENT)
  end

  def test_a_placement_disposition_not_on_file_is_refused
    assert_refused_before_amhg(/placement disposition is not on file/i, "placement_not_on_file",
                               **FULL_KWARGS, placement_disposition: NOT_ON_FILE)
  end

  def test_an_inactive_placement_disposition_is_refused
    assert_refused_before_amhg(/placement disposition is inactive/i, "placement_inactive",
                               **FULL_KWARGS, placement_disposition: INACTIVE_PLACEMENT)
  end

  # The build's reply for a record no visit has: "0~Update Chief Complaint".
  def test_an_amhg_error_reply_is_outcome_unknown_and_echoes_no_broker_text
    replay_with(RPC, 0, CapturedReplies.raw(SLUG, "save_record_not_on_file"))

    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    refute_empty amhg_calls
    assert_outcome_unknown(err)
    refute_includes err.message, "Update Chief Complaint"
  end

  # --- read-backs that do not match what was sent -----------------------------

  def test_values_the_read_back_does_not_hold_are_not_confirmed
    [
      { chief_complaint: "SYNTH OTHER CC" },
      { referred_to: "SYN OTHER" },
      { note: "#{NOTE}SYNTH extra line\n" },
      { comment: "SYNTH other comment" }
    ].each do |change|
      replay
      err = assert_raises(BH::SaveError, change.keys.first.to_s) { BH.save_progress_note(**FULL_KWARGS, **change) }
      assert_outcome_unknown(err)
    end
  end

  # The note's LFs are content: a SOAP read-back of the empty-comment save's
  # one-line note does not confirm the multi-line note.
  def test_a_soap_read_back_of_another_note_is_not_confirmed
    replay_with(RPC_SOAP, 0, flow_raw("save_empty_comment", RPC_SOAP, 0))

    assert_outcome_unknown(assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) })
  end

  # --- a wire lost or never sent ----------------------------------------------

  def test_a_wire_lost_during_the_write_is_outcome_unknown_and_keeps_the_cause
    [ RpmsRpc::Client::ConnectionError, RpmsRpc::Client::RpcTimeoutError, RpmsRpc::Client::RpcMError,
      RpmsRpc::Client::RpcError ].each do |klass|
      replay.fail_on(RPC, klass.new("SYNTH_PN_TRAP"))
      err = assert_raises(BH::SaveError, klass.name) { BH.save_progress_note(**FULL_KWARGS) }
      assert_outcome_unknown(err)
      assert_kind_of klass, err.cause
      refute_includes err.message, "SYNTH_PN_TRAP"
    end
  end

  # A read-back the session is refused, or that loses the wire, comes after
  # the write: the outcome is unknown, not a refusal.
  def test_a_read_back_that_fails_after_the_write_is_outcome_unknown
    [ [ RPC_SOAP, RpmsRpc::Client::RpcRefusedError ], [ RPC_SOAP, RpmsRpc::Client::RpcNotAvailableError ],
      [ RPC_COMM, RpmsRpc::Client::RpcRefusedError ], [ GETS, RpmsRpc::Client::RpcMError ] ].each do |rpc, klass|
      replay
      # The DDR read-back is the third GETS; fail_on takes the next call, so
      # spend the two pre-reads first.
      skip_gets = rpc == GETS ? 2 : 0
      @client.define_singleton_method(:call_rpc_raw) do |name, *params|
        if name == rpc && (skip_gets -= 1).negative?
          @calls << { rpc: name, params: params }
          raise klass, "synthetic"
        end
        super(name, *params)
      end
      err = assert_raises(BH::SaveError, "#{rpc} #{klass}") { BH.save_progress_note(**FULL_KWARGS) }
      refute_empty amhg_calls
      assert_outcome_unknown(err)
    end
  end

  def test_with_no_context_a_lost_wire_still_rebinds_the_fileman_context
    replay(context: nil).fail_on(RPC, RpmsRpc::Client::RpcTimeoutError.new("synthetic"))

    err = assert_raises(BH::SaveError) { capture_io { BH.save_progress_note(**FULL_KWARGS) } }
    assert_kind_of RpmsRpc::Client::RpcTimeoutError, err.cause
    assert_equal AmhgReplay::FILEMAN_CONTEXT, @client.current_context
  end

  def test_a_refused_rebind_does_not_replace_the_lost_wire
    replay(context: nil).fail_on(RPC, RpmsRpc::Client::RpcMError.new("synthetic"))
    @client.refuse_bind(AmhgReplay::FILEMAN_CONTEXT)

    err = assert_raises(BH::SaveError) { capture_io { BH.save_progress_note(**FULL_KWARGS) } }
    assert_kind_of RpmsRpc::Client::RpcMError, err.cause
    assert_nil @client.current_context
  end

  def test_a_frame_too_long_to_send_is_nothing_sent_not_outcome_unknown
    replay(context: nil).fail_on(RPC, RpmsRpc::Client::FrameTooLongError.new("synthetic"), sent: false)

    err = assert_raises(BH::SaveError) { capture_io { BH.save_progress_note(**FULL_KWARGS) } }
    refute_match(/outcome unknown/i, err.message)
    assert_match(/nothing was sent/i, err.message)
    assert_kind_of RpmsRpc::Client::FrameTooLongError, err.cause
    assert_equal AmhgReplay::FILEMAN_CONTEXT, @client.current_context
  end

  def test_an_rpc_the_session_may_not_run_is_not_wrapped
    [ RpmsRpc::Client::RpcNotAvailableError, RpmsRpc::Client::RpcRefusedError ].each do |klass|
      replay.fail_on(RPC, klass.new("synthetic"), sent: false)
      assert_raises(klass) { BH.save_progress_note(**FULL_KWARGS) }
      assert_empty amhg_calls
    end
  end

  # --- argument guards: refused before any RPC --------------------------------

  def test_save_error_is_a_subclass_of_rpms_rpc_error
    assert_operator BH::SaveError, :<, RpmsRpc::Error
  end

  def test_nil_for_any_keyword_is_refused
    KWARG_KEYS.each { |key| assert_input_validation_refusal(key, **FULL_KWARGS, key => nil) }
  end

  def test_an_unknown_keyword_is_an_argument_error
    @client = AmhgReplay.silent
    assert_raises(ArgumentError) { BH.save_progress_note(**FULL_KWARGS, esign: true) }
    assert_empty @client.calls
  end

  def test_a_record_ien_or_patient_that_is_not_a_positive_integer_is_refused
    [ "", "   ", "0", "-1", "abc" ].each do |bad|
      assert_input_validation_refusal("record_ien #{bad.inspect}", **FULL_KWARGS, record_ien: bad)
      assert_input_validation_refusal("patient #{bad.inspect}", **FULL_KWARGS, patient: bad) unless bad.strip.empty?
    end
  end

  def test_a_blank_note_or_a_whitespace_comment_is_refused
    [ "", "   ", "\n\n" ].each { |bad| assert_input_validation_refusal("note", **FULL_KWARGS, note: bad) }
    [ "   ", "\t" ].each { |bad| assert_input_validation_refusal("comment", **FULL_KWARGS, comment: bad) }
  end

  def test_chief_complaint_referred_to_and_placement_outside_their_bounds_are_refused
    [ "A", "X" * 81, "#{'a' * 79}é", "@" ].each do |bad|
      assert_input_validation_refusal("chief #{bad}", **FULL_KWARGS, chief_complaint: bad)
    end
    [ "A", "X" * 31, " @ " ].each do |bad|
      assert_input_validation_refusal("referred #{bad}", **FULL_KWARGS, referred_to: bad)
    end
    %w[0 -1 abc].each do |bad|
      assert_input_validation_refusal("placement #{bad}", **FULL_KWARGS, placement_disposition: bad)
    end
  end

  def test_separators_and_control_characters_are_refused
    KWARG_KEYS.each do |key|
      assert_input_validation_refusal("pipe #{key}", **FULL_KWARGS, key => "a|b")
      assert_input_validation_refusal("caret #{key}", **FULL_KWARGS, key => "a^b")
    end
    [ "\x1e", "\x1f", "\x01", "\x7f", "\r", "\n" ].each do |bad|
      assert_input_validation_refusal("chief #{bad.inspect}", **FULL_KWARGS, chief_complaint: bad)
    end
    assert_input_validation_refusal("note CR", **FULL_KWARGS, note: "a\rb")
    assert_input_validation_refusal("comment CR", **FULL_KWARGS, comment: "a\rb")
  end

  def test_text_that_is_not_valid_utf8_is_refused
    assert_input_validation_refusal("invalid bytes", **FULL_KWARGS, note: String.new("\xC0\x80", encoding: Encoding::ASCII_8BIT))
    assert_input_validation_refusal("UTF-16", **FULL_KWARGS, chief_complaint: "SYNTH".encode("UTF-16LE"))
    %i[chief_complaint note comment referred_to].each do |key|
      assert_input_validation_refusal("U+FFFD #{key}", **FULL_KWARGS, key => "SYNTH � text")
    end
  end

  # --- registry ---------------------------------------------------------------

  def test_retry_safety_classifies_save_progress_note_as_non_idempotent_write
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(BH, :save_progress_note)
  end

  def test_required_rpcs_lists_amhg_save_progress_notes_under_behavioral_health
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    assert_includes doc.fetch("modules").fetch("RpmsRpc::BehavioralHealth"), RPC
  end
end
