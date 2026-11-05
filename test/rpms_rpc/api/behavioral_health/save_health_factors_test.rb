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

# AMHG SAVE HEALTH FACTORS — HF^AMHGSVF (AMHGSVF.m:277-305), MODHF/DELHF^AMHGEVF.
# Four pipe pieces: DM|REC|HF list|patient. HF list items are *-joined; each item is
# name~level~qty~comment (R="~"). Mode E replaces all factors not sent (DELHF).
class BehavioralHealthSaveHealthFactorsTest < Minitest::Test
  BH = RpmsRpc::BehavioralHealth
  Ddr = RpmsRpc::DdrFileman
  RPC = "AMHG SAVE HEALTH FACTORS"
  RS = "\x1e"
  US = "\x1f"

  ROOT = File.expand_path("../../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")
  RPCS_MD_PATH = File.join(ROOT, "docs/rpcs.md")
  MAPPINGS_PATH = File.join(ROOT, "lib/rpms_rpc/mappings/ihs.rb")

  BH_VISIT_FILE = "9002011"
  HF_FILE = "9002011.08"
  HF_XREF = "AD"
  HF_FROM = "0"
  HF_FIELDS = ".01;.02;.03;.04;.06;81101"
  HF_FLAGS = "IP"
  HF_MAX = "25"
  PRE_EDIT_FIELDS = ".08;1112"
  PRE_EDIT_FLAGS = "I"

  PATIENT = "990543"
  OTHER_PATIENT = "990544"
  RECORD_IEN = "8801"
  RECORD_ADD = "8802"

  HF_ONE_NAME = "TOBACCO"
  HF_ONE_LEVEL = "CURRENT"
  HF_ONE_QTY = "2"
  HF_ONE_COMMENT = "SYN HF ONE"
  HF_TWO_NAME = "EXERCISE"
  HF_TWO_LEVEL = "YES"
  HF_TWO_QTY = ""
  HF_TWO_COMMENT = ""

  WIRE_EDIT_TWO =
    "E|#{RECORD_IEN}|#{HF_ONE_NAME}~#{HF_ONE_LEVEL}~#{HF_ONE_QTY}~#{HF_ONE_COMMENT}*" \
    "#{HF_TWO_NAME}~#{HF_TWO_LEVEL}~#{HF_TWO_QTY}~#{HF_TWO_COMMENT}|#{PATIENT}".freeze

  WIRE_ADD_ONE =
    "A|#{RECORD_ADD}|#{HF_ONE_NAME}~#{HF_ONE_LEVEL}~#{HF_ONE_QTY}~#{HF_ONE_COMMENT}|#{PATIENT}".freeze

  EDIT_KWARGS = {
    record_ien: RECORD_IEN,
    patient: PATIENT,
    mode: :edit,
    health_factors: [
      { name: HF_ONE_NAME, level: HF_ONE_LEVEL, quantity: HF_ONE_QTY, comment: HF_ONE_COMMENT },
      { name: HF_TWO_NAME, level: HF_TWO_LEVEL, quantity: HF_TWO_QTY, comment: HF_TWO_COMMENT }
    ]
  }.freeze

  ADD_KWARGS = {
    record_ien: RECORD_ADD,
    patient: PATIENT,
    mode: :add,
    health_factors: [
      { name: HF_ONE_NAME, level: HF_ONE_LEVEL, quantity: HF_ONE_QTY, comment: HF_ONE_COMMENT }
    ]
  }.freeze

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_edit_pins_the_exact_four_piece_wire_with_star_joined_hf_items
    seed_success(WIRE_EDIT_TWO, RECORD_IEN, **EDIT_KWARGS)
    BH.save_health_factors(**EDIT_KWARGS)

    call = save_call
    refute_nil call
    assert_equal RPC, call[:rpc]
    assert_equal WIRE_EDIT_TWO, call[:params].first
    pieces = call[:params].first.split("|", -1)
    assert_equal 4, pieces.length
    assert_equal "E", pieces[0]
  end

  def test_add_pins_mode_a_on_the_wire
    seed_success(WIRE_ADD_ONE, RECORD_ADD, **ADD_KWARGS)
    BH.save_health_factors(**ADD_KWARGS)

    assert_equal "A", save_call[:params].first.split("|", -1)[0]
    assert_equal WIRE_ADD_ONE, save_call[:params].first
  end

  def test_save_health_factors_runs_under_amhgrpc_and_restores_the_callers_context
    seed_success(WIRE_EDIT_TWO, RECORD_IEN, **EDIT_KWARGS)
    caller_context = @mock.current_context

    BH.save_health_factors(**EDIT_KWARGS)

    assert_equal "AMHGRPC", save_call[:context]
    assert_equal caller_context, @mock.current_context
  end

  def test_edit_success_returns_record_ien_after_pre_edit_and_hf_lister_readback
    seed_success(WIRE_EDIT_TWO, RECORD_IEN, **EDIT_KWARGS)
    assert_equal RECORD_IEN, BH.save_health_factors(**EDIT_KWARGS)
    assert_hf_lister_after_save(RECORD_IEN)
  end

  def test_refuses_blank_record_ien_on_edit_without_rpc
    assert_pre_call_refusal(**EDIT_KWARGS.merge(record_ien: ""))
    assert_pre_call_refusal(**EDIT_KWARGS.merge(record_ien: "   "))
  end

  def test_refuses_blank_record_ien_on_add_without_rpc
    assert_pre_call_refusal(**ADD_KWARGS.merge(record_ien: ""))
  end

  def test_raises_on_zero_tilde_error_reply
    seed_post_amhg_trap(WIRE_EDIT_TWO, **EDIT_KWARGS) do
      seed_amhg_text(WIRE_EDIT_TWO, "T00030Result#{RS}0~Add Health Factor#{RS}#{US}")
    end
    err = assert_raises(BH::SaveError) { BH.save_health_factors(**EDIT_KWARGS) }
    assert_amhg_reached
    assert_match(/Add Health Factor|outcome unknown|may have been/i, err.message)
  end

  def test_raises_on_empty_reply
    seed_post_amhg_trap(WIRE_EDIT_TWO, **EDIT_KWARGS) { seed_amhg_text(WIRE_EDIT_TWO, "") }
    assert_raises(BH::SaveError) { BH.save_health_factors(**EDIT_KWARGS) }
  end

  def test_refuses_pipe_tilde_star_and_control_characters_in_hf_comment_without_rpc
    [ "|", "~", "*", "^", RS, "\n" ].each do |bad|
      factors = [ { name: HF_ONE_NAME, level: HF_ONE_LEVEL, quantity: "1", comment: "SYN#{bad}" } ]
      assert_input_validation_refusal(/separator|control/i, **EDIT_KWARGS.merge(health_factors: factors))
    end
  end

  def test_refuses_pipe_in_hf_name_or_level_without_rpc
    assert_input_validation_refusal(/separator|control/i,
                                   **EDIT_KWARGS.merge(health_factors: [
                                     { name: "BAD|NAME", level: HF_ONE_LEVEL, quantity: "1", comment: "" }
                                   ]))
    assert_input_validation_refusal(/separator|control/i,
                                   **EDIT_KWARGS.merge(health_factors: [
                                     { name: HF_ONE_NAME, level: "A|B", quantity: "1", comment: "" }
                                   ]))
  end

  def test_retry_safety_classifies_save_health_factors_as_non_idempotent_write
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(BH, :save_health_factors)
  end

  def test_required_rpcs_lists_amhg_save_health_factors_under_behavioral_health
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    assert_includes doc.fetch("modules").fetch("RpmsRpc::BehavioralHealth"), RPC
  end

  def test_rpcs_md_documents_save_health_factors_verified_under_amhgrpc
    text = File.read(RPCS_MD_PATH)
    assert_includes text, "`AMHG SAVE HEALTH FACTORS`"
    assert_includes text, "HF^AMHGSVF"
    assert_includes text, "AMHGRPC"
  end

  def test_mappings_ihs_defines_amhg_save_health_factors
    assert_includes File.read(MAPPINGS_PATH), "DataMapper.define(:amhg_save_health_factors)",
                    "production mapping :amhg_save_health_factors must ship with save_health_factors"
  end

  private

  def save_call
    @mock.received_calls.find { |c| c[:rpc] == RPC }
  end

  def amhg_calls
    @mock.received_calls.select { |c| c[:rpc] == RPC }
  end

  def assert_amhg_reached
    refute_empty amhg_calls
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
    seed_pre_edit_patient(kwargs.fetch(:record_ien), kwargs.fetch(:patient))
    seed_amhg_text(wire, success_body(ien))
    seed_hf_lister(ien, kwargs.fetch(:health_factors))
  end

  def seed_post_amhg_trap(wire, **kwargs)
    seed_pre_edit_patient(kwargs.fetch(:record_ien), kwargs.fetch(:patient))
    yield if block_given?
  end

  def seed_pre_edit_patient(ien, patient)
    key = Ddr.gets_entry_param(
      file: BH_VISIT_FILE, iens: "#{ien},", fields: PRE_EDIT_FIELDS, flags: PRE_EDIT_FLAGS
    ).to_s
    body = <<~BODY
      [Data]
      #{BH_VISIT_FILE}^#{ien}^.08^#{patient}^PATIENT,SYNTH
      #{BH_VISIT_FILE}^#{ien}^1110^^
      #{BH_VISIT_FILE}^#{ien}^1112^^SIGNED
    BODY
    @mock.seed(:ddr_gets_entry_data, key, body)
  end

  def seed_hf_lister(record_ien, factors)
    list_key = [
      HF_FILE, HF_XREF, record_ien.to_s, HF_FROM,
      "I $P(^(0),U,3)=#{record_ien}", HF_FIELDS, HF_FLAGS, HF_MAX
    ].join("|")
    lines = factors.each_with_index.map do |row, idx|
      ien = (idx + 1).to_s
      "#{HF_FILE}^#{ien}^.01^#{row[:name]}^EXT^#{row[:name]}\n" \
        "#{HF_FILE}^#{ien}^.02^#{PATIENT}^PAT^#{HF_FILE}^#{ien}^.03^#{record_ien}^VISIT\n" \
        "#{HF_FILE}^#{ien}^.04^#{row[:level]}^EXT^#{HF_FILE}^#{ien}^.06^#{row[:quantity]}^QTY\n" \
        "#{HF_FILE}^#{ien}^81101^#{row[:comment]}^EXT"
    end
    body = "[Data]\n#{lines.join("\n")}"
    @mock.seed(:ddr_lister, list_key, body)
  end

  def assert_hf_lister_after_save(record_ien)
    idx_save = @mock.received_calls.index { |c| c[:rpc] == RPC }
    refute_nil idx_save
    later = @mock.received_calls[(idx_save + 1)..]
    refute_nil later.find { |c| c[:rpc] == "DDR LISTER" && c[:params].first.to_s.include?(HF_FILE) },
               "expected HF DDR LISTER read-back after #{RPC}"
  end

  def assert_pre_call_refusal(**kwargs)
    before = amhg_calls.length
    assert_raises(BH::SaveError) { BH.save_health_factors(**kwargs) }
    assert_equal before, amhg_calls.length
  end

  def assert_input_validation_refusal(pattern, **kwargs)
    err = assert_raises(BH::SaveError) { BH.save_health_factors(**kwargs) }
    assert_empty amhg_calls
    assert_match pattern, err.message
  end
end
