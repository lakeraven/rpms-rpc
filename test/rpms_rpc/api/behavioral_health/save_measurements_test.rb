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

# AMHG SAVE MEASUREMENTS — MSR^AMHGSVF (AMHGSVF.m:343-370), MODMSR/DELMSR^AMHGEVF.
# Four pipe pieces: DM|REC|MSR list|patient. MSR items are *-joined; each item is
# name~~value~provider (empty second ~ piece). Mode E replaces measurements not sent.
class BehavioralHealthSaveMeasurementsTest < Minitest::Test
  BH = RpmsRpc::BehavioralHealth
  Ddr = RpmsRpc::DdrFileman
  RPC = "AMHG SAVE MEASUREMENTS"
  RS = "\x1e"
  US = "\x1f"

  ROOT = File.expand_path("../../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")
  RPCS_MD_PATH = File.join(ROOT, "docs/rpcs.md")
  MAPPINGS_PATH = File.join(ROOT, "lib/rpms_rpc/mappings/ihs.rb")

  BH_VISIT_FILE = "9002011"
  MSR_FILE = "9002011.12"
  MSR_XREF = "AD"
  MSR_FROM = "0"
  MSR_FIELDS = ".01;.02;.03;.04;1204"
  MSR_FLAGS = "IP"
  MSR_MAX = "25"
  PRE_EDIT_FIELDS = ".08;1112"
  PRE_EDIT_FLAGS = "I"

  PATIENT = "990545"
  OTHER_PATIENT = "990546"
  RECORD_IEN = "8801"
  RECORD_ADD = "8803"
  PROVIDER = "501"

  MSR_WEIGHT = "WEIGHT"
  MSR_VALUE = "185"
  MSR_PAIN = "PAIN"
  MSR_PAIN_VAL = "3"

  WIRE_EDIT_TWO =
    "E|#{RECORD_IEN}|#{MSR_WEIGHT}~~#{MSR_VALUE}~#{PROVIDER}*" \
    "#{MSR_PAIN}~~#{MSR_PAIN_VAL}~#{PROVIDER}|#{PATIENT}".freeze

  WIRE_ADD_ONE =
    "A|#{RECORD_ADD}|#{MSR_WEIGHT}~~#{MSR_VALUE}~#{PROVIDER}|#{PATIENT}".freeze

  EDIT_KWARGS = {
    record_ien: RECORD_IEN,
    patient: PATIENT,
    mode: :edit,
    measurements: [
      { name: MSR_WEIGHT, value: MSR_VALUE, provider: PROVIDER },
      { name: MSR_PAIN, value: MSR_PAIN_VAL, provider: PROVIDER }
    ]
  }.freeze

  ADD_KWARGS = {
    record_ien: RECORD_ADD,
    patient: PATIENT,
    mode: :add,
    measurements: [
      { name: MSR_WEIGHT, value: MSR_VALUE, provider: PROVIDER }
    ]
  }.freeze

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_edit_pins_the_exact_four_piece_wire_with_star_joined_msr_items
    seed_success(WIRE_EDIT_TWO, RECORD_IEN, **EDIT_KWARGS)
    BH.save_measurements(**EDIT_KWARGS)

    call = save_call
    refute_nil call
    assert_equal RPC, call[:rpc]
    assert_equal WIRE_EDIT_TWO, call[:params].first
    pieces = call[:params].first.split("|", -1)
    assert_equal 4, pieces.length
    assert_equal "E", pieces[0]
    assert_includes pieces[2], "~~", "each MSR item keeps the empty second ~ piece"
  end

  def test_add_pins_mode_a_on_the_wire
    seed_success(WIRE_ADD_ONE, RECORD_ADD, **ADD_KWARGS)
    BH.save_measurements(**ADD_KWARGS)

    assert_equal "A", save_call[:params].first.split("|", -1)[0]
  end

  def test_save_measurements_runs_under_amhgrpc_and_restores_the_callers_context
    seed_success(WIRE_EDIT_TWO, RECORD_IEN, **EDIT_KWARGS)
    caller_context = @mock.current_context

    BH.save_measurements(**EDIT_KWARGS)

    assert_equal "AMHGRPC", save_call[:context]
    assert_equal caller_context, @mock.current_context
  end

  def test_edit_success_returns_record_ien_after_pre_edit_and_msr_lister_readback
    seed_success(WIRE_EDIT_TWO, RECORD_IEN, **EDIT_KWARGS)
    assert_equal RECORD_IEN, BH.save_measurements(**EDIT_KWARGS)
    assert_msr_lister_after_save(RECORD_IEN)
  end

  def test_refuses_blank_record_ien_on_edit_without_rpc
    assert_pre_call_refusal(**EDIT_KWARGS.merge(record_ien: ""))
  end

  def test_refuses_blank_record_ien_on_add_without_rpc
    assert_pre_call_refusal(**ADD_KWARGS.merge(record_ien: ""))
  end

  def test_raises_on_zero_tilde_error_reply
    seed_post_amhg_trap(WIRE_EDIT_TWO, **EDIT_KWARGS) do
      seed_amhg_text(WIRE_EDIT_TWO, "T00030Result#{RS}0~Edit Measurement#{RS}#{US}")
    end
    err = assert_raises(BH::SaveError) { BH.save_measurements(**EDIT_KWARGS) }
    assert_amhg_reached
    assert_match(/Edit Measurement|outcome unknown|may have been/i, err.message)
  end

  def test_raises_on_empty_reply
    seed_post_amhg_trap(WIRE_EDIT_TWO, **EDIT_KWARGS) { seed_amhg_text(WIRE_EDIT_TWO, "") }
    assert_raises(BH::SaveError) { BH.save_measurements(**EDIT_KWARGS) }
  end

  def test_refuses_pipe_tilde_star_and_control_characters_in_measurement_value_without_rpc
    [ "|", "~", "*", "^", RS, "\n" ].each do |bad|
      rows = [ { name: MSR_WEIGHT, value: "1#{bad}2", provider: PROVIDER } ]
      assert_input_validation_refusal(/separator|control/i, **EDIT_KWARGS.merge(measurements: rows))
    end
  end

  def test_refuses_pipe_in_measurement_name_without_rpc
    rows = [ { name: "BAD|MSR", value: MSR_VALUE, provider: PROVIDER } ]
    assert_input_validation_refusal(/separator|control/i, **EDIT_KWARGS.merge(measurements: rows))
  end

  def test_retry_safety_classifies_save_measurements_as_non_idempotent_write
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(BH, :save_measurements)
  end

  def test_required_rpcs_lists_amhg_save_measurements_under_behavioral_health
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    assert_includes doc.fetch("modules").fetch("RpmsRpc::BehavioralHealth"), RPC
  end

  def test_rpcs_md_documents_save_measurements_verified_under_amhgrpc
    text = File.read(RPCS_MD_PATH)
    assert_includes text, "`AMHG SAVE MEASUREMENTS`"
    assert_includes text, "MSR^AMHGSVF"
    assert_includes text, "AMHGRPC"
  end

  def test_mappings_ihs_defines_amhg_save_measurements
    assert_includes File.read(MAPPINGS_PATH), "DataMapper.define(:amhg_save_measurements)",
                    "production mapping :amhg_save_measurements must ship with save_measurements"
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
    seed_msr_lister(ien, kwargs.fetch(:measurements))
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

  def seed_msr_lister(record_ien, measurements)
    list_key = [
      MSR_FILE, MSR_XREF, record_ien.to_s, MSR_FROM,
      "I $P(^(0),U,3)=#{record_ien}", MSR_FIELDS, MSR_FLAGS, MSR_MAX
    ].join("|")
    lines = measurements.each_with_index.map do |row, idx|
      ien = (idx + 1).to_s
      "#{MSR_FILE}^#{ien}^.01^#{row[:name]}^EXT^#{MSR_FILE}^#{ien}^.02^#{PATIENT}^PAT\n" \
        "#{MSR_FILE}^#{ien}^.03^#{record_ien}^VISIT^#{MSR_FILE}^#{ien}^.04^#{row[:value]}^VAL\n" \
        "#{MSR_FILE}^#{ien}^1204^#{row[:provider]}^PROV"
    end
    body = "[Data]\n#{lines.join("\n")}"
    @mock.seed(:ddr_lister, list_key, body)
  end

  def assert_msr_lister_after_save(record_ien)
    idx_save = @mock.received_calls.index { |c| c[:rpc] == RPC }
    refute_nil idx_save
    later = @mock.received_calls[(idx_save + 1)..]
    refute_nil later.find { |c| c[:rpc] == "DDR LISTER" && c[:params].first.to_s.include?(MSR_FILE) },
               "expected MSR DDR LISTER read-back after #{RPC}"
  end

  def assert_pre_call_refusal(**kwargs)
    before = amhg_calls.length
    assert_raises(BH::SaveError) { BH.save_measurements(**kwargs) }
    assert_equal before, amhg_calls.length
  end

  def assert_input_validation_refusal(pattern, **kwargs)
    err = assert_raises(BH::SaveError) { BH.save_measurements(**kwargs) }
    assert_empty amhg_calls
    assert_match pattern, err.message
  end
end
