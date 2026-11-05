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

# AMHG SAVE SCREENING — SCREEN^AMHGSVF (AMHGSVF.m:307-341), SCREEN^AMHGEVF.
# Nineteen pipe pieces (DM|REC|A|AC|D|DC|IP|IPC|PP|P|APRV|DPRV|IPRV|S|SC|SPRV|SS|SSC|SSIP).
# Edit-only on the wire (piece 1 always E); piece 10 (P) is bound by pre-edit .08.
class BehavioralHealthSaveScreeningTest < Minitest::Test
  BH = RpmsRpc::BehavioralHealth
  Ddr = RpmsRpc::DdrFileman
  RPC = "AMHG SAVE SCREENING"
  RPC_READ = "AMHG GET VISIT SCREENING"
  RS = "\x1e"
  US = "\x1f"

  ROOT = File.expand_path("../../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")
  RPCS_MD_PATH = File.join(ROOT, "docs/rpcs.md")
  MAPPINGS_PATH = File.join(ROOT, "lib/rpms_rpc/mappings/ihs.rb")

  BH_VISIT_FILE = "9002011"
  PRE_EDIT_FIELDS = ".08;1112"
  PRE_EDIT_FLAGS = "I"

  PATIENT = "990541"
  OTHER_PATIENT = "990542"
  RECORD_IEN = "8801"
  PROVIDER_ONE = "501"
  PROVIDER_TWO = "502"

  ALC_RESULT = "Y"
  ALC_COMMENT = "SYN ALC COMMENT"
  DEP_RESULT = "N"
  DEP_COMMENT = ""
  IPV_RESULT = "Y"
  IPV_COMMENT = "SYN IPV"
  PP_PIECE = "SYN PP"
  SUI_RESULT = "Y"
  SUI_COMMENT = "SYN SUI"
  SS_RESULT = "N"
  SS_COMMENT = ""
  SSIP_PIECE = "SYN SSIP"

  WIRE_FULL =
    "E|#{RECORD_IEN}|#{ALC_RESULT}|#{ALC_COMMENT}|#{DEP_RESULT}|#{DEP_COMMENT}|" \
    "#{IPV_RESULT}|#{IPV_COMMENT}|#{PP_PIECE}|#{PATIENT}|#{PROVIDER_ONE}|#{PROVIDER_TWO}|" \
    "#{PROVIDER_ONE}|#{SUI_RESULT}|#{SUI_COMMENT}|#{PROVIDER_TWO}|#{SS_RESULT}|#{SS_COMMENT}|#{SSIP_PIECE}".freeze

  FULL_KWARGS = {
    record_ien: RECORD_IEN,
    patient: PATIENT,
    alcohol_result: ALC_RESULT,
    alcohol_comment: ALC_COMMENT,
    depression_result: DEP_RESULT,
    depression_comment: DEP_COMMENT,
    ipv_result: IPV_RESULT,
    ipv_comment: IPV_COMMENT,
    wellness_primary_provider: PP_PIECE,
    alcohol_screening_provider: PROVIDER_ONE,
    depression_screening_provider: PROVIDER_TWO,
    ipv_screening_provider: PROVIDER_ONE,
    suicide_result: SUI_RESULT,
    suicide_comment: SUI_COMMENT,
    suicide_screening_provider: PROVIDER_TWO,
    suicide_screening_result: SS_RESULT,
    suicide_screening_comment: SS_COMMENT,
    suicide_screening_ipv_provider: SSIP_PIECE
  }.freeze

  KWARG_KEYS = FULL_KWARGS.keys.freeze

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_edit_pins_the_exact_nineteen_piece_wire_string
    seed_success(WIRE_FULL, RECORD_IEN, **FULL_KWARGS)
    BH.save_screening(**FULL_KWARGS)

    call = save_call
    refute_nil call
    assert_equal RPC, call[:rpc]
    assert_equal 1, call[:params].length
    assert_equal WIRE_FULL, call[:params].first
    pieces = call[:params].first.split("|", -1)
    assert_equal 19, pieces.length
    assert_equal "E", pieces[0]
  end

  def test_save_screening_runs_under_amhgrpc_and_restores_the_callers_context
    seed_success(WIRE_FULL, RECORD_IEN, **FULL_KWARGS)
    caller_context = @mock.current_context

    BH.save_screening(**FULL_KWARGS)

    assert_equal "AMHGRPC", save_call[:context]
    assert_equal caller_context, @mock.current_context
    assert_equal [ "AMHGRPC", caller_context ], @mock.context_binds
  end

  def test_edit_success_returns_the_record_ien_after_pre_edit_and_readback
    seed_success(WIRE_FULL, RECORD_IEN, **FULL_KWARGS)
    assert_equal RECORD_IEN, BH.save_screening(**FULL_KWARGS)
    assert_pre_edit_ddr_call("#{RECORD_IEN},")
  end

  def test_refuses_blank_record_ien_on_edit_without_rpc
    assert_pre_call_refusal(**FULL_KWARGS.merge(record_ien: ""))
    assert_pre_call_refusal(**FULL_KWARGS.merge(record_ien: "   "))
  end

  def test_refuses_nil_for_any_keyword_without_rpc
    KWARG_KEYS.each do |key|
      assert_pre_call_refusal(**FULL_KWARGS.merge(key => nil), label: key.to_s)
    end
  end

  def test_raises_on_zero_tilde_error_reply_not_success
    seed_post_amhg_trap(WIRE_FULL, **FULL_KWARGS) do
      seed_amhg_text(WIRE_FULL, "T00030Result#{RS}0~Edit Screening#{RS}#{US}")
    end
    err = assert_raises(BH::SaveError) { BH.save_screening(**FULL_KWARGS) }
    assert_amhg_reached
    refute_match(/\A#{Regexp.escape(RECORD_IEN)}\z/, err.message)
    assert_match(/Edit Screening|outcome unknown|may have been/i, err.message)
  end

  def test_raises_on_empty_reply_after_amhg_call
    seed_post_amhg_trap(WIRE_FULL, **FULL_KWARGS) { seed_amhg_text(WIRE_FULL, "") }
    err = assert_raises(BH::SaveError) { BH.save_screening(**FULL_KWARGS) }
    assert_amhg_reached
    assert_match(/outcome unknown|may have been/i, err.message)
  end

  def test_raises_when_reply_ien_is_zero_or_missing
    seed_post_amhg_trap(WIRE_FULL, **FULL_KWARGS) { seed_success(WIRE_FULL, "0") }
    assert_raises(BH::SaveError) { BH.save_screening(**FULL_KWARGS) }
    seed_post_amhg_trap(WIRE_FULL, **FULL_KWARGS) do
      seed_amhg_text(WIRE_FULL, "T00030Result#{RS}#{RS}#{US}")
    end
    assert_raises(BH::SaveError) { BH.save_screening(**FULL_KWARGS) }
  end

  def test_refuses_pipe_tilde_star_caret_and_control_characters_in_free_text_without_rpc
    separators = [ "|", "~", "*", "^", RS, US, "\x01", "ok\nbad" ]
    separators.each do |bad|
      assert_input_validation_refusal(/separator|control/i, **FULL_KWARGS.merge(alcohol_comment: "SYN#{bad}TH"))
      assert_input_validation_refusal(/separator|control/i, **FULL_KWARGS.merge(ipv_comment: bad.to_s))
    end
  end

  def test_pre_edit_refuses_wrong_patient_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, OTHER_PATIENT)
    assert_pre_call_refusal(**FULL_KWARGS)
  end

  def test_pre_edit_refuses_signed_visit_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT, signed: true)
    assert_pre_call_refusal(**FULL_KWARGS)
  end

  def test_retry_safety_classifies_save_screening_as_non_idempotent_write
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(BH, :save_screening)
  end

  def test_required_rpcs_lists_amhg_save_screening_under_behavioral_health
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    list = doc.fetch("modules").fetch("RpmsRpc::BehavioralHealth")
    assert_includes list, RPC
    assert_includes list, RPC_READ
  end

  def test_rpcs_md_documents_save_screening_verified_under_amhgrpc
    text = File.read(RPCS_MD_PATH)
    assert_includes text, "`AMHG SAVE SCREENING`"
    assert_includes text, "SCREEN^AMHGSVF"
    assert_includes text, "AMHGRPC"
  end

  def test_mappings_ihs_defines_amhg_save_screening
    assert_includes File.read(MAPPINGS_PATH), "DataMapper.define(:amhg_save_screening)",
                    "production mapping :amhg_save_screening must ship with save_screening"
  end

  private

  def save_call
    @mock.received_calls.find { |c| c[:rpc] == RPC }
  end

  def amhg_calls
    @mock.received_calls.select { |c| c[:rpc] == RPC }
  end

  def assert_amhg_reached
    refute_empty amhg_calls, "expected #{RPC} to be called"
  end

  def seed_amhg_text(wire, body)
    blobs = @mock.instance_variable_get(:@text_blobs)
    blobs[RPC] ||= {}
    blobs[RPC][wire] = body
  end

  def success_body(ien)
    "T00030Result#{RS}#{ien}#{RS}#{US}"
  end

  def seed_success(wire, ien, **kwargs)
    seed_pre_edit_patient(kwargs.fetch(:record_ien, RECORD_IEN), kwargs.fetch(:patient, PATIENT))
    seed_amhg_text(wire, success_body(ien))
  end

  def seed_post_amhg_trap(wire, **kwargs)
    seed_pre_edit_patient(kwargs.fetch(:record_ien, RECORD_IEN), kwargs.fetch(:patient, PATIENT))
    yield if block_given?
  end

  def ddr_gets_key(file:, iens:, fields:, flags:)
    Ddr.gets_entry_param(file: file, iens: iens, fields: fields, flags: flags).to_s
  end

  def seed_pre_edit_patient(ien, patient, signed: false)
    key = ddr_gets_key(
      file: BH_VISIT_FILE, iens: "#{ien},", fields: PRE_EDIT_FIELDS, flags: PRE_EDIT_FLAGS
    )
    signed_at = signed ? "3251031.12" : ""
    body = <<~BODY
      [Data]
      #{BH_VISIT_FILE}^#{ien}^.08^#{patient}^PATIENT,SYNTH
      #{BH_VISIT_FILE}^#{ien}^1110^^
      #{BH_VISIT_FILE}^#{ien}^1112^#{signed_at}^SIGNED
    BODY
    @mock.seed(:ddr_gets_entry_data, key, body)
  end

  def assert_pre_edit_ddr_call(iens)
    call = @mock.received_calls.find do |c|
      next false unless c[:rpc] == "DDR GETS ENTRY DATA"

      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["FIELDS"] == PRE_EDIT_FIELDS && p["IENS"] == iens
    end
    refute_nil call, "expected pre-edit DDR GETS on #{iens}"
  end

  def assert_pre_call_refusal(**kwargs)
    kwargs.delete(:label)
    before = amhg_calls.length
    err = assert_raises(BH::SaveError) { BH.save_screening(**kwargs) }
    assert_equal before, amhg_calls.length, "AMHG SAVE SCREENING must not be called"
    err
  end

  def assert_input_validation_refusal(pattern, **kwargs)
    err = assert_raises(BH::SaveError) { BH.save_screening(**kwargs) }
    assert_empty amhg_calls
    assert_match pattern, err.message
  end
end
