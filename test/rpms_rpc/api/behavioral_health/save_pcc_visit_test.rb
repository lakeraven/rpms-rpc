# frozen_string_literal: true

require "minitest/autorun"
require "delegate"
require "json"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/mappings"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/retry_safety"

# AMHG CREATE/EDIT VISIT — PCC^AMHGPCC (AMHGPCC.m:10-28), EN^AMHBHRU (AMHBHRU.m).
# Mock AMHG replies via @mock.seed_text(:amhg_create_edit_visit, ...) once mapping ships.
class BehavioralHealthSavePccVisitTest < Minitest::Test
  BH = RpmsRpc::BehavioralHealth
  Ddr = RpmsRpc::DdrFileman
  RPC = "AMHG CREATE/EDIT VISIT"
  RS = "\x1e" # $C(30)
  US = "\x1f" # $C(31)

  ROOT = File.expand_path("../../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  BH_VISIT_FILE = "9002011"
  V_VISIT_FILE = "9000010"
  PRE_VISIT_IEN_FIELDS = ".08;.16"
  PRE_VISIT_IEN_FLAGS = "I"
  V_VISIT_PATIENT_FIELD = ".05"
  V_VISIT_PATIENT_FLAGS = "I"
  POST_READBACK_BH_FIELDS = ".08;.16"
  POST_READBACK_BH_FLAGS = "IE"
  POST_READBACK_V_FIELDS = ".05"
  POST_READBACK_V_FLAGS = "IE"

  PATIENT = "990537"
  OTHER_PATIENT = "990538"
  RECORD_IEN = "8801"
  PCC_VISIT_IEN = "44101"
  OTHER_PCC_VISIT = "44102"
  EXISTING_PCC_LINK = "44099"

  ACTIVITY_TYPE_MISSING = "Activity Type Missing!"
  UNKNOWN_BROKER_TAIL = "SYNTH_UNKNOWN_PCC_REFUSAL_X537"
  SECRET_MARKER = "UNIQUE_PHI_MARKER_ISSUE537"

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # --- wire (PCC^AMHGPCC) ---------------------------------------------------

  def test_pins_two_piece_wire_with_blank_second_piece_when_visit_ien_omitted
    seed_fallback_success(record_ien: RECORD_IEN, reply_ien: PCC_VISIT_IEN)
    BH.save_pcc_visit(record_ien: RECORD_IEN)

    call = pcc_call
    refute_nil call, "expected #{RPC}"
    assert_equal 1, call[:params].length
    assert_equal "#{RECORD_IEN}|", call[:params].first
    assert_equal RPC, call[:rpc]
  end

  def test_pins_two_piece_wire_when_visit_ien_is_given
    seed_explicit_visit_success(
      record_ien: RECORD_IEN, visit_ien: PCC_VISIT_IEN, reply_ien: PCC_VISIT_IEN, patient: PATIENT
    )
    BH.save_pcc_visit(record_ien: RECORD_IEN, visit_ien: PCC_VISIT_IEN)

    assert_equal "#{RECORD_IEN}|#{PCC_VISIT_IEN}", pcc_call[:params].first
  end

  def test_runs_under_amhgrpc_and_restores_the_callers_context
    seed_fallback_success(record_ien: RECORD_IEN, reply_ien: PCC_VISIT_IEN)
    caller_context = @mock.current_context

    BH.save_pcc_visit(record_ien: RECORD_IEN)

    call = pcc_call
    assert_equal "AMHGRPC", call[:context]
    assert_equal caller_context, @mock.current_context
    assert_equal [ "AMHGRPC", caller_context ], @mock.context_binds
  end

  # --- pre-call refusals (no RPC) -------------------------------------------

  def test_save_error_is_a_subclass_of_rpms_rpc_error
    assert_operator BH::SaveError, :<, RpmsRpc::Error
  end

  def test_refuses_non_positive_integer_record_ien_without_rpc
    %w[0 -1 abc].each do |bad|
      assert_pre_call_refusal(record_ien: bad, label: "record_ien=#{bad}")
    end
    assert_pre_call_refusal(record_ien: "", label: "blank record_ien")
    assert_pre_call_refusal(record_ien: "   ", label: "space record_ien")
  end

  def test_refuses_non_positive_integer_visit_ien_without_rpc
    assert_pre_call_refusal(record_ien: RECORD_IEN, visit_ien: "0")
    assert_pre_call_refusal(record_ien: RECORD_IEN, visit_ien: "-1")
    assert_pre_call_refusal(record_ien: RECORD_IEN, visit_ien: "abc")
    assert_pre_call_refusal(record_ien: RECORD_IEN, visit_ien: "")
    assert_pre_call_refusal(record_ien: RECORD_IEN, visit_ien: "   ")
  end

  def test_accepts_positive_integer_record_and_visit_ien_as_integers
    seed_explicit_visit_success(
      record_ien: RECORD_IEN.to_i, visit_ien: PCC_VISIT_IEN.to_i,
      reply_ien: PCC_VISIT_IEN, patient: PATIENT
    )
    assert_equal PCC_VISIT_IEN, BH.save_pcc_visit(record_ien: RECORD_IEN.to_i, visit_ien: PCC_VISIT_IEN.to_i)
  end

  def test_with_visit_ien_pins_pre_amhg_ddr_gets_on_bh_dot08_dot16_and_v_visit_dot05
    seed_explicit_visit_success(
      record_ien: RECORD_IEN, visit_ien: PCC_VISIT_IEN, reply_ien: PCC_VISIT_IEN, patient: PATIENT
    )
    BH.save_pcc_visit(record_ien: RECORD_IEN, visit_ien: PCC_VISIT_IEN)

    amhg_index = positions_of { |c| c[:rpc] == RPC }.first
    refute_nil amhg_index

    bh_idx = pre_bh_visit_gets_index(record_ien: RECORD_IEN)
    v_idx = pre_v_visit_gets_index(visit_ien: PCC_VISIT_IEN)
    refute_nil bh_idx
    refute_nil v_idx
    assert_operator bh_idx, :<, amhg_index
    assert_operator v_idx, :<, amhg_index
  end

  def test_with_visit_ien_refuses_when_v_visit_is_missing_without_amhg_rpc
    seed_bh_patient_link(record_ien: RECORD_IEN, patient: PATIENT, pcc_ien: "")
    err = assert_raises(BH::SaveError) do
      BH.save_pcc_visit(record_ien: RECORD_IEN, visit_ien: PCC_VISIT_IEN)
    end
    refute_empty err.message
    assert_empty pcc_calls
  end

  def test_with_visit_ien_refuses_when_v_visit_patient_differs_from_bh_dot08_without_amhg_rpc
    seed_bh_patient_link(record_ien: RECORD_IEN, patient: PATIENT, pcc_ien: "")
    seed_v_visit_patient(visit_ien: PCC_VISIT_IEN, patient: OTHER_PATIENT)
    assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN, visit_ien: PCC_VISIT_IEN) }
    assert_empty pcc_calls
  end

  def test_with_visit_ien_refuses_when_bh_dot16_already_links_a_different_visit_without_amhg_rpc
    seed_bh_patient_link(record_ien: RECORD_IEN, patient: PATIENT, pcc_ien: EXISTING_PCC_LINK)
    seed_v_visit_patient(visit_ien: PCC_VISIT_IEN, patient: PATIENT)
    assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN, visit_ien: PCC_VISIT_IEN) }
    assert_empty pcc_calls
  end

  # --- success read-back ----------------------------------------------------

  def test_success_returns_pcc_visit_ien_after_post_call_ddr_confirmation
    seed_fallback_success(record_ien: RECORD_IEN, reply_ien: PCC_VISIT_IEN, patient: PATIENT)
    assert_equal PCC_VISIT_IEN, BH.save_pcc_visit(record_ien: RECORD_IEN)
    assert_post_readback_ddr_calls(record_ien: RECORD_IEN, pcc_ien: PCC_VISIT_IEN, patient: PATIENT)
  end

  def test_success_refuses_when_post_readback_dot16_differs_from_reply
    seed_fallback_success(record_ien: RECORD_IEN, reply_ien: PCC_VISIT_IEN, patient: PATIENT,
                          readback_pcc_ien: OTHER_PCC_VISIT)
    err = assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN) }
    assert_amhg_reached
    assert_match(/may have been changed|not confirmed/i, err.message)
  end

  def test_success_refuses_when_v_visit_dot05_differs_from_bh_dot08
    seed_fallback_success(record_ien: RECORD_IEN, reply_ien: PCC_VISIT_IEN, patient: PATIENT,
                          readback_visit_patient: OTHER_PATIENT)
    err = assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN) }
    assert_amhg_reached
    assert_match(/may have been changed|not confirmed/i, err.message)
  end

  # --- broker error rows ----------------------------------------------------

  def test_maps_activity_type_missing_to_save_error_and_says_nothing_was_linked
    seed_fallback_reply(record_ien: RECORD_IEN, body: error_body(ACTIVITY_TYPE_MISSING))
    err = assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN) }
    assert_amhg_reached
    assert_match(/Activity Type Missing!/i, err.message)
    assert_match(/nothing.*linked|not.*linked|no PCC visit.*linked/i, err.message)
  end

  def test_unknown_zero_tilde_error_does_not_echo_broker_text
    seed_fallback_reply(record_ien: RECORD_IEN, body: error_body(UNKNOWN_BROKER_TAIL))
    err = assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN) }
    assert_amhg_reached
    refute_includes err.message, UNKNOWN_BROKER_TAIL
  end

  def test_blank_success_row_raises_save_error_about_no_link_and_possible_removal
    seed_fallback_reply(record_ien: RECORD_IEN, body: blank_success_body)
    err = assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN) }
    assert_amhg_reached
    assert_match(/no PCC visit.*linked|not linked/i, err.message)
    assert_match(/removed|may have been/i, err.message)
  end

  def test_with_visit_ien_refuses_when_reply_names_a_different_pcc_visit_ien
    seed_explicit_visit_success(
      record_ien: RECORD_IEN, visit_ien: PCC_VISIT_IEN, reply_ien: OTHER_PCC_VISIT, patient: PATIENT
    )
    err = assert_raises(BH::SaveError) do
      BH.save_pcc_visit(record_ien: RECORD_IEN, visit_ien: PCC_VISIT_IEN)
    end
    assert_amhg_reached
    refute_includes err.message, OTHER_PCC_VISIT
    refute_includes err.message, PCC_VISIT_IEN
  end

  # --- malformed / transport (outcome unknown, no PHI) ----------------------

  def test_raises_on_m_error_row_without_end_separator
    seed_post_amhg_trap(record_ien: RECORD_IEN) { seed_fallback_reply(record_ien: RECORD_IEN, body: "M ERROR|synthetic trap#{RS}") }
    err = assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN) }
    assert_amhg_reached
    assert_post_call_ambiguity(err)
  end

  def test_raises_when_reply_has_no_t00030result_header
    seed_post_amhg_trap(record_ien: RECORD_IEN) { seed_fallback_reply(record_ien: RECORD_IEN, body: "#{PCC_VISIT_IEN}#{RS}#{US}") }
    err = assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN) }
    assert_amhg_reached
    assert_post_call_ambiguity(err)
  end

  def test_raises_when_reply_has_more_than_one_data_row
    body = "T00030Result#{RS}#{PCC_VISIT_IEN}#{RS}extra#{RS}#{US}"
    seed_post_amhg_trap(record_ien: RECORD_IEN) { seed_fallback_reply(record_ien: RECORD_IEN, body: body) }
    err = assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN) }
    assert_amhg_reached
    assert_post_call_ambiguity(err)
  end

  def test_pcc_rpc_timeout_becomes_save_error_with_ambiguous_outcome
    seed_pre_amhg_for_fallback(record_ien: RECORD_IEN)
    wrapper = TimeoutOnPccVisit.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN) }
    assert_amhg_reached
    assert_post_call_ambiguity(err)
    assert_kind_of RpmsRpc::Client::RpcTimeoutError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_pcc_connection_error_becomes_save_error_with_ambiguous_outcome
    seed_pre_amhg_for_fallback(record_ien: RECORD_IEN)
    wrapper = ConnectionErrorOnPccVisit.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN) }
    assert_amhg_reached
    assert_post_call_ambiguity(err)
    assert_kind_of RpmsRpc::Client::ConnectionError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_ambiguity_message_does_not_echo_record_ien_or_broker_trap_text
    seed_post_amhg_trap(record_ien: RECORD_IEN) do
      seed_fallback_reply(record_ien: RECORD_IEN, body: "M ERROR|#{SECRET_MARKER}#{RS}")
    end
    err = assert_raises(BH::SaveError) { BH.save_pcc_visit(record_ien: RECORD_IEN) }
    assert_amhg_reached
    refute_includes err.message, SECRET_MARKER
    refute_includes err.message, RECORD_IEN
    refute_includes err.message, PATIENT
  end

  # --- registration ---------------------------------------------------------

  def test_retry_safety_classifies_save_pcc_visit_as_non_idempotent_write
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(BH, :save_pcc_visit)
  end

  def test_required_rpcs_lists_amhg_create_edit_visit_under_behavioral_health
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    assert_includes doc.fetch("modules").fetch("RpmsRpc::BehavioralHealth"), RPC
  end

  private

  def wire_param(record_ien, visit_ien = nil)
    visit_piece = visit_ien.nil? ? "" : visit_ien.to_s
    "#{record_ien}|#{visit_piece}"
  end

  def success_body(pcc_ien)
    "T00030Result#{RS}#{pcc_ien}#{RS}#{US}"
  end

  def error_body(message)
    "T00030Result#{RS}0~#{message}#{RS}#{US}"
  end

  def blank_success_body
    "T00030Result#{RS}#{RS}#{US}"
  end

  def seed_reply(wire, body)
    @mock.seed_text(:amhg_create_edit_visit, wire, body)
  end

  def seed_fallback_reply(record_ien:, body:)
    seed_reply(wire_param(record_ien), body)
  end

  def seed_pre_amhg_for_fallback(record_ien:)
    # Fallback path: AMHG uses #9002011 .16 when piece 2 is blank; no pre-read required by contract.
  end

  def seed_fallback_success(record_ien:, reply_ien:, patient: PATIENT, readback_pcc_ien: nil,
                            readback_visit_patient: nil)
    seed_fallback_reply(record_ien: record_ien, body: success_body(reply_ien))
    seed_post_readback(
      record_ien: record_ien,
      pcc_ien: readback_pcc_ien || reply_ien,
      patient: patient,
      visit_patient: readback_visit_patient || patient
    )
  end

  def seed_explicit_visit_success(record_ien:, visit_ien:, reply_ien:, patient:,
                                  readback_pcc_ien: nil, readback_visit_patient: nil)
    seed_bh_patient_link(record_ien: record_ien, patient: patient, pcc_ien: "")
    seed_v_visit_patient(visit_ien: visit_ien, patient: patient)
    seed_reply(wire_param(record_ien, visit_ien), success_body(reply_ien))
    seed_post_readback(
      record_ien: record_ien,
      pcc_ien: readback_pcc_ien || reply_ien,
      patient: patient,
      visit_patient: readback_visit_patient || patient
    )
  end

  def seed_post_amhg_trap(record_ien:)
    seed_pre_amhg_for_fallback(record_ien: record_ien)
    yield
  end

  def ddr_gets_key(file:, iens:, fields:, flags:)
    Ddr.gets_entry_param(file: file, iens: iens, fields: fields, flags: flags).to_s
  end

  def seed_bh_patient_link(record_ien:, patient:, pcc_ien:)
    key = ddr_gets_key(
      file: BH_VISIT_FILE, iens: "#{record_ien},",
      fields: PRE_VISIT_IEN_FIELDS, flags: PRE_VISIT_IEN_FLAGS
    )
    body = "[Data]\n" \
           "#{BH_VISIT_FILE}^#{record_ien}^.08^#{patient}^PATIENT,SYNTH\n" \
           "#{BH_VISIT_FILE}^#{record_ien}^.16^#{pcc_ien}^VISIT"
    @mock.seed(:ddr_gets_entry_data, key, body)
  end

  def seed_v_visit_patient(visit_ien:, patient:)
    key = ddr_gets_key(
      file: V_VISIT_FILE, iens: "#{visit_ien},",
      fields: V_VISIT_PATIENT_FIELD, flags: V_VISIT_PATIENT_FLAGS
    )
    body = "[Data]\n#{V_VISIT_FILE}^#{visit_ien}^.05^#{patient}^PATIENT,SYNTH"
    @mock.seed(:ddr_gets_entry_data, key, body)
  end

  def seed_post_readback(record_ien:, pcc_ien:, patient:, visit_patient:)
    bh_key = ddr_gets_key(
      file: BH_VISIT_FILE, iens: "#{record_ien},",
      fields: POST_READBACK_BH_FIELDS, flags: POST_READBACK_BH_FLAGS
    )
    bh_body = "[Data]\n" \
              "#{BH_VISIT_FILE}^#{record_ien}^.08^#{patient}^PATIENT,SYNTH\n" \
              "#{BH_VISIT_FILE}^#{record_ien}^.16^#{pcc_ien}^VISIT"
    @mock.seed(:ddr_gets_entry_data, bh_key, bh_body)

    v_key = ddr_gets_key(
      file: V_VISIT_FILE, iens: "#{pcc_ien},",
      fields: POST_READBACK_V_FIELDS, flags: POST_READBACK_V_FLAGS
    )
    v_body = "[Data]\n#{V_VISIT_FILE}^#{pcc_ien}^.05^#{visit_patient}^PATIENT,SYNTH"
    @mock.seed(:ddr_gets_entry_data, v_key, v_body)
  end

  def positions_of
    @mock.received_calls.each_with_index.select { |call, _| yield call }.map(&:last)
  end

  def pcc_call
    @mock.received_calls.find { |c| c[:rpc] == RPC }
  end

  def pcc_calls
    @mock.received_calls.select { |c| c[:rpc] == RPC }
  end

  def ddr_gets_calls
    @mock.received_calls.select { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
  end

  def pre_bh_visit_gets_index(record_ien:)
    positions_of do |c|
      next false unless c[:rpc] == "DDR GETS ENTRY DATA"

      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["IENS"] == "#{record_ien}," &&
        p["FIELDS"] == PRE_VISIT_IEN_FIELDS && p["FLAGS"] == PRE_VISIT_IEN_FLAGS
    end.first
  end

  def pre_v_visit_gets_index(visit_ien:)
    positions_of do |c|
      next false unless c[:rpc] == "DDR GETS ENTRY DATA"

      p = c[:params].first
      p["FILE"] == V_VISIT_FILE && p["IENS"] == "#{visit_ien}," &&
        p["FIELDS"] == V_VISIT_PATIENT_FIELD && p["FLAGS"] == V_VISIT_PATIENT_FLAGS
    end.first
  end

  def assert_post_readback_ddr_calls(record_ien:, pcc_ien:, patient:)
    bh = ddr_gets_calls.find do |c|
      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["IENS"] == "#{record_ien}," && p["FIELDS"] == POST_READBACK_BH_FIELDS
    end
    refute_nil bh, "expected post-call BH read-back"

    v = ddr_gets_calls.find do |c|
      p = c[:params].first
      p["FILE"] == V_VISIT_FILE && p["IENS"] == "#{pcc_ien}," && p["FIELDS"] == POST_READBACK_V_FIELDS
    end
    refute_nil v, "expected post-call V VISIT read-back for patient #{patient}"
  end

  def assert_amhg_reached
    refute_empty pcc_calls, "expected #{RPC} before post-call SaveError"
  end

  def assert_pre_call_refusal(label: nil, **kwargs)
    err = if label.is_a?(String)
            assert_raises(BH::SaveError, label) { BH.save_pcc_visit(**kwargs) }
          else
            assert_raises(BH::SaveError) { BH.save_pcc_visit(**kwargs) }
          end
    assert_empty pcc_calls, "pre-call refusal must not RPC#{label ? " (#{label})" : ""}"
    err
  end

  def assert_post_call_ambiguity(err)
    assert_match(/outcome unknown|may have been changed|may have been removed/i, err.message)
    refute_includes err.message, PATIENT
  end
end

class TimeoutOnPccVisit < SimpleDelegator
  def call_rpc_global_array(rpc_name, *params)
    if rpc_name == "AMHG CREATE/EDIT VISIT"
      super
      raise RpmsRpc::Client::RpcTimeoutError, "AMHG CREATE/EDIT VISIT timed out (synthetic)"
    end

    super
  end
end

class ConnectionErrorOnPccVisit < SimpleDelegator
  def call_rpc_global_array(rpc_name, *params)
    if rpc_name == "AMHG CREATE/EDIT VISIT"
      super
      raise RpmsRpc::Client::ConnectionError, "AMHG CREATE/EDIT VISIT connection lost (synthetic)"
    end

    super
  end
end
