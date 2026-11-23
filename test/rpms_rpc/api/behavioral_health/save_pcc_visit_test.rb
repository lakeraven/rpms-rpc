# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require "rpms_rpc/mappings"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/retry_safety"
require_relative "amhg_replay"

# AMHG CREATE/EDIT VISIT: PCC^AMHGPCC (AMHGPCC.m:10-28), EN^AMHBHRU (AMHBHRU.m).
#
# The guard and refusal cases, read from the conversations the pinned build
# had with BehavioralHealth.save_pcc_visit
# (test/fixtures/captured_replies/amhg-create-edit-visit.yml), on one BH visit
# for synthetic patient DFN 990033: the build's "0~Activity Type Missing!"
# refusal with and without a PCC visit named, and the refusals the gem
# reaches from the build's pre-reads (a PCC visit of another patient, a PCC
# visit or a BH record not on file). test/live/behavioral_health_save_pcc_visit_live_test.rb
# proves the build's refusal live (rpms-rpc#622, option b), and
# test/live/behavioral_health_pcc_visit_patient_live_test.rb proves the
# other-patient refusal live on a target that does link (openrpms#1284): stock
# AMHG CREATE/EDIT VISIT does not refuse another patient's PCC visit, so this
# refusal is the gem's alone.
#
# The pinned build never links: its site PCC link is off and EN^AMHBHRU
# refuses a visit without an activity type, activity time and the other
# CHECKREC fields (AMHBHRU.m:22-42). No build has sent a linking reply, so the
# read-back after a link is not covered here.
class BehavioralHealthSavePccVisitTest < Minitest::Test
  BH = RpmsRpc::BehavioralHealth
  SLUG = "amhg-create-edit-visit"
  RPC = "AMHG CREATE/EDIT VISIT"
  GETS = "DDR GETS ENTRY DATA"
  V_VISIT_FILE = "9000010"

  ROOT = File.expand_path("../../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  def self.inputs(flow, at) = CapturedReplies.flow(SLUG, flow).fetch(at).fetch("inputs").first

  RECORD_IEN = inputs("activity_type_missing", 0).fetch("IENS").delete_suffix(",")
  PCC_VISIT_IEN = inputs("activity_type_missing_with_visit", 1).fetch("IENS").delete_suffix(",")
  OTHER_PATIENT_VISIT = inputs("visit_of_another_patient", 1).fetch("IENS").delete_suffix(",")
  RECORD_NOT_ON_FILE = inputs("record_not_on_file", 0).fetch("IENS").delete_suffix(",")
  VISIT_NOT_ON_FILE = "999999"
  PATIENT = "990033"

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow, **opts) = @client = AmhgReplay.flow(SLUG, flow, **opts)
  def sent = @client.calls.select { |c| c[:rpc].is_a?(String) }.map { |c| [ c[:rpc], c[:params] ] }
  def amhg_calls = @client.calls.select { |c| c[:rpc] == RPC }

  def assert_refused_before_amhg(pattern, flow, **kwargs)
    replay(flow)
    err = assert_raises(BH::SaveError) { BH.save_pcc_visit(**kwargs) }
    assert_match pattern, err.message
    assert_empty amhg_calls, "nothing may reach #{RPC}"
    assert_equal CapturedReplies.flow_calls(SLUG, flow), sent
    err
  end

  def assert_input_validation_refusal(**kwargs)
    @client = AmhgReplay.silent
    assert_raises(BH::SaveError, kwargs.inspect) { BH.save_pcc_visit(**kwargs) }
    assert_empty @client.calls, "input validation must refuse before any RPC"
  end

  # --- the build's refusal ----------------------------------------------------

  def test_activity_type_missing_is_a_save_error_that_says_nothing_was_linked
    replay("activity_type_missing")

    err = assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN) }
    assert_match(/Activity Type Missing!/, err.message)
    assert_match(/nothing.*linked|not.*linked|no PCC visit.*linked/i, err.message)
    refute_includes err.message, PATIENT
  end

  # The BH pre-read (.08, .16), then the two-piece wire with a blank second
  # piece: each request is the one the build answered.
  def test_each_request_is_the_one_the_build_answered
    replay("activity_type_missing")
    assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN) }

    assert_equal CapturedReplies.flow_calls(SLUG, "activity_type_missing"), sent
    assert_equal [ "#{RECORD_IEN}|" ], amhg_calls.first[:params]
  end

  # A named PCC visit is read (.05, .11) before the write and sent as piece 2.
  def test_a_named_pcc_visit_is_read_before_the_write_and_sent
    replay("activity_type_missing_with_visit")

    err = assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN, visit_ien: PCC_VISIT_IEN) }
    assert_match(/Activity Type Missing!/, err.message)
    assert_equal CapturedReplies.flow_calls(SLUG, "activity_type_missing_with_visit"), sent
    assert_equal [ "#{RECORD_IEN}|#{PCC_VISIT_IEN}" ], amhg_calls.first[:params]
  end

  def test_integer_record_and_visit_iens_send_the_same_wire
    replay("activity_type_missing_with_visit")

    assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN.to_i, visit_ien: PCC_VISIT_IEN.to_i) }
    assert_equal CapturedReplies.flow_calls(SLUG, "activity_type_missing_with_visit"), sent
  end

  def test_the_write_runs_under_amhgrpc_and_the_pre_reads_under_the_fileman_context
    replay("activity_type_missing_with_visit")
    assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN, visit_ien: PCC_VISIT_IEN) }

    assert_equal "AMHGRPC", amhg_calls.first[:context]
    @client.calls.select { |c| c[:rpc] == GETS }.each { |c| assert_equal AmhgReplay::FILEMAN_CONTEXT, c[:context] }
    assert_equal [ "AMHGRPC", AmhgReplay::FILEMAN_CONTEXT ], @client.binds
    assert_equal AmhgReplay::FILEMAN_CONTEXT, @client.current_context
  end

  # A session that declared no context is re-bound to the FileMan context
  # after the write, so it is not left under AMHGRPC.
  def test_a_session_with_no_context_is_rebound_to_the_fileman_context
    replay("activity_type_missing", context: nil)
    assert_raises(BH::SaveError) { capture_io { BH.save_pcc_visit(record_ien: RECORD_IEN) } }

    assert_equal [ "AMHGRPC", AmhgReplay::FILEMAN_CONTEXT ], @client.binds
    assert_equal AmhgReplay::FILEMAN_CONTEXT, @client.current_context
  end

  # --- refusals the build's pre-reads lead to ---------------------------------

  def test_a_pcc_visit_of_another_patient_is_refused
    assert_refused_before_amhg(/patient does not match/i, "visit_of_another_patient",
                               record_ien: RECORD_IEN, visit_ien: OTHER_PATIENT_VISIT)
  end

  def test_a_pcc_visit_not_on_file_is_refused
    assert_refused_before_amhg(/not on file/i, "visit_not_on_file", record_ien: RECORD_IEN, visit_ien: VISIT_NOT_ON_FILE)
  end

  def test_a_bh_record_not_on_file_is_refused_without_naming_it
    err = assert_refused_before_amhg(/behavioral health record could not be read/i, "record_not_on_file",
                                     record_ien: RECORD_NOT_ON_FILE)
    refute_includes err.message, RECORD_NOT_ON_FILE
  end

  # --- a wire lost or never sent ----------------------------------------------

  def test_a_wire_lost_during_the_write_is_outcome_unknown_and_keeps_the_cause
    [ RpmsRpc::Client::ConnectionError, RpmsRpc::Client::RpcTimeoutError, RpmsRpc::Client::RpcMError,
      RpmsRpc::Client::RpcError ].each do |klass|
      replay("activity_type_missing").fail_on(RPC, klass.new("SYNTH_PCC_TRAP"))
      err = assert_raises(BH::SaveError, klass.name) { BH.save_pcc_visit(record_ien: RECORD_IEN) }
      assert_match(/outcome (is )?unknown|may have been/i, err.message)
      assert_kind_of klass, err.cause
      refute_includes err.message, "SYNTH_PCC_TRAP"
      refute_includes err.message, RECORD_IEN
    end
  end

  def test_with_no_context_a_lost_wire_still_rebinds_the_fileman_context
    replay("activity_type_missing", context: nil).fail_on(RPC, RpmsRpc::Client::RpcTimeoutError.new("synthetic"))

    assert_raises(BH::SaveError) { capture_io { BH.save_pcc_visit(record_ien: RECORD_IEN) } }
    assert_equal [ "AMHGRPC", AmhgReplay::FILEMAN_CONTEXT ], @client.binds
    assert_equal AmhgReplay::FILEMAN_CONTEXT, @client.current_context
  end

  # Raised inside a host's own rescue, a refused re-bind is still a
  # SaveError that keeps the lost wire as its cause.
  def test_a_refused_rebind_inside_a_host_rescue_keeps_the_lost_wire
    replay("activity_type_missing", context: nil).fail_on(RPC, RpmsRpc::Client::RpcTimeoutError.new("synthetic"))
    @client.refuse_bind(AmhgReplay::FILEMAN_CONTEXT)

    err = begin
      raise "host"
    rescue StandardError
      assert_raises(BH::SaveError) { capture_io { BH.save_pcc_visit(record_ien: RECORD_IEN) } }
    end
    assert_kind_of RpmsRpc::Client::RpcTimeoutError, err.cause
  end

  def test_a_frame_too_long_to_send_is_nothing_sent_not_outcome_unknown
    replay("activity_type_missing", context: nil).fail_on(RPC, RpmsRpc::Client::FrameTooLongError.new("synthetic"),
                                                          sent: false)

    err = assert_raises(BH::SaveError) { capture_io { BH.save_pcc_visit(record_ien: RECORD_IEN) } }
    refute_match(/outcome unknown/i, err.message)
    assert_match(/nothing was sent/i, err.message)
    assert_kind_of RpmsRpc::Client::FrameTooLongError, err.cause
    assert_equal AmhgReplay::FILEMAN_CONTEXT, @client.current_context
  end

  def test_an_rpc_the_session_may_not_run_is_not_wrapped
    [ RpmsRpc::Client::RpcNotAvailableError, RpmsRpc::Client::RpcRefusedError ].each do |klass|
      replay("activity_type_missing").fail_on(RPC, klass.new("synthetic"), sent: false)
      assert_raises(klass) { BH.save_pcc_visit(record_ien: RECORD_IEN) }
      assert_empty amhg_calls
    end
  end

  # --- argument guards: refused before any RPC --------------------------------

  def test_save_error_is_a_subclass_of_rpms_rpc_error
    assert_operator BH::SaveError, :<, RpmsRpc::Error
  end

  def test_a_record_or_visit_ien_that_is_not_a_positive_integer_is_refused
    [ "0", "-1", "abc", "", "   ", "01", "1.5" ].each do |bad|
      assert_input_validation_refusal(record_ien: bad)
      assert_input_validation_refusal(record_ien: RECORD_IEN, visit_ien: bad)
    end
  end

  # --- registry ---------------------------------------------------------------

  def test_retry_safety_classifies_save_pcc_visit_as_non_idempotent_write
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(BH, :save_pcc_visit)
  end

  def test_required_rpcs_lists_amhg_create_edit_visit_under_behavioral_health
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    assert_includes doc.fetch("modules").fetch("RpmsRpc::BehavioralHealth"), RPC
  end
end
