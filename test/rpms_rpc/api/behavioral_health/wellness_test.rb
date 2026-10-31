# frozen_string_literal: true

require "minitest/autorun"
require "delegate"
require "json"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/retry_safety"

# AMHG SAVE SCREENING / AMHG SAVE MEASUREMENTS / AMHG GET VISIT MSR DATA ENTRY
# (rpms-rpc#540). Hermetic contract for RpmsRpc::BehavioralHealth::Wellness.
# Synthetic data only.
class BehavioralHealthWellnessTest < Minitest::Test
  Ddr = RpmsRpc::DdrFileman
  RS = "\x1e" # $C(30)
  US = "\x1f" # $C(31)

  ROOT = File.expand_path("../../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  BH_VISIT_FILE = "9002011"
  RPC_SCREENING = "AMHG SAVE SCREENING"
  RPC_MEASUREMENTS = "AMHG SAVE MEASUREMENTS"
  RPC_MSR_READ = "AMHG GET VISIT MSR DATA ENTRY"

  PRE_EDIT_FIELDS =
    ".08;1112;1401;1402;1403;1404;1405;1406;1407;1408;1409;1410;1501;1601;1701;1901;2001".freeze
  PRE_EDIT_FLAGS = "I"

  PATIENT = "990540"
  OTHER_PATIENT = "990541"
  PROVIDER = "412"
  RECORD_IEN = "8840"

  SYNTH_DEPRESSION_COMMENT = "Synthetic depression screening note for spec"
  PHI_COMMENT = "Unique PHI marker xyzzy screening comment"

  MSR_HEADER =
    "T00010BMXIEN^T00010Measurement^T00030Description^T00030Value^T00010Provider IEN^T00030Provider".freeze

  SCREENING_EXTERNAL = {
    alcohol: {
      "N" => "NEGATIVE", "P" => "POSITIVE", "UAS" => "UNABLE TO SCREEN",
      "REF" => "PATIENT REFUSED SCREENING", "RF" => "REFERRAL NEEDED"
    },
    depression: {
      "N" => "NEGATIVE", "P" => "POSITIVE", "UAS" => "UNABLE TO SCREEN",
      "REF" => "PATIENT REFUSED SCREENING", "RF" => "REFERRAL NEEDED"
    },
    ipv: {
      "N" => "NEGATIVE", "PR" => "PRESENT", "PAP" => "PRESENT AND PAST", "PA" => "PAST",
      "REF" => "PATIENT REFUSED SCREENING", "UAS" => "UNABLE TO SCREEN", "RF" => "REFERRAL NEEDED"
    },
    suicide_risk: {
      "L" => "LOW", "M" => "MODERATE", "H" => "HIGH", "RF" => "REFERRAL NEEDED",
      "REF" => "PATIENT REFUSED SCREENING", "UAS" => "UNABLE TO SCREEN"
    },
    suicide_screening: {
      "N" => "NEGATIVE", "AP" => "ACUTE POSITIVE", "NAP" => "NON-ACUTE POSITIVE",
      "REF" => "PATIENT REFUSED SCREENING", "UAS" => "UNABLE TO SCREEN"
    }
  }.freeze

  BASELINE_INTERNAL = {
    "1403" => "N", "1404" => "411", "1601" => "Alcohol baseline note",
    "1405" => "N", "1406" => "411", "1701" => "Depression baseline note",
    "1401" => "PR", "1402" => "413", "1501" => "Ipv baseline note",
    "1407" => "L", "1408" => "414", "1901" => "Risk baseline note",
    "1409" => "N", "1410" => "415", "2001" => "Screen baseline note"
  }.freeze

  WELLNESS = begin
    require "rpms_rpc/api/behavioral_health/wellness"
    RpmsRpc::BehavioralHealth::Wellness
  rescue LoadError
    nil
  end

  RpmsRpc::DataMapper.define(:wellness_spec_save_screening) do |m|
    m.rpc RPC_SCREENING
    m.text_blob :body
  end
  RpmsRpc::DataMapper.define(:wellness_spec_save_measurements) do |m|
    m.rpc RPC_MEASUREMENTS
    m.text_blob :body
  end
  RpmsRpc::DataMapper.define(:wellness_spec_visit_msr_entry) do |m|
    m.rpc RPC_MSR_READ
    m.text_blob :body
  end

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def wellness
    flunk "RpmsRpc::BehavioralHealth::Wellness is not implemented (rpms-rpc#540)" unless WELLNESS

    WELLNESS
  end

  def save_error_class
    wellness
    RpmsRpc::BehavioralHealth::Wellness::SaveError
  end

  # --- registry --------------------------------------------------------------

  def test_required_rpcs_lists_wellness_write_and_read_rpcs
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    rpcs = doc.fetch("modules").fetch("RpmsRpc::BehavioralHealth::Wellness")

    assert_includes rpcs, RPC_SCREENING
    assert_includes rpcs, RPC_MEASUREMENTS
    assert_includes rpcs, RPC_MSR_READ
  end

  def test_retry_safety_classifies_both_writes_as_non_idempotent
    wellness
    assert_equal :non_idempotent_write,
                 RpmsRpc::RetrySafety.for(RpmsRpc::BehavioralHealth::Wellness, :save_screening)
    assert_equal :non_idempotent_write,
                 RpmsRpc::RetrySafety.for(RpmsRpc::BehavioralHealth::Wellness, :save_measurements)
  end

  def test_save_error_is_a_subclass_of_rpms_rpc_error
    assert_operator save_error_class, :<, RpmsRpc::Error
  end

  # --- save_screening wire + success -----------------------------------------

  def test_save_screening_pins_the_exact_nineteen_piece_wire_resending_unchanged_screenings
    depression_only = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(depression_only)
    seed_screening_success(wire, depression_only)

    wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: depression_only)

    call = screening_call
    refute_nil call
    assert_equal RPC_SCREENING, call[:rpc]
    assert_equal 1, call[:params].length
    assert_equal wire, call[:params].first
    assert_equal 19, call[:params].first.split("|", -1).length
    assert_equal "E", call[:params].first.split("|", -1)[0]
    pieces = call[:params].first.split("|", -1)
    assert_equal "NEGATIVE", pieces[2], "alcohol result resent from pre-read"
    assert_equal "Alcohol baseline note", pieces[3]
    assert_equal "411", pieces[10]
    assert_equal "POSITIVE", pieces[4]
    assert_equal SYNTH_DEPRESSION_COMMENT, pieces[5]
    assert_equal PROVIDER, pieces[11]
  end

  def test_save_screening_runs_under_amhgrpc_and_restores_the_callers_context
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    seed_screening_success(wire, screenings)
    caller_context = @mock.current_context

    wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)

    assert_equal "AMHGRPC", screening_call[:context]
    assert_equal caller_context, @mock.current_context
  end

  def test_save_screening_success_returns_all_five_screenings_from_readback
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    seed_screening_success(wire, screenings)

    result = wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)

    assert_equal RECORD_IEN, result.fetch(:record_ien)
    five = result.fetch(:screenings)
    %i[alcohol depression ipv suicide_risk suicide_screening].each do |key|
      assert five.key?(key), "expected #{key} in return hash"
    end
    assert_equal "P", five.fetch(:depression).fetch(:result)
    assert_equal PROVIDER, five.fetch(:depression).fetch(:provider)
    assert_equal SYNTH_DEPRESSION_COMMENT, five.fetch(:depression).fetch(:comment)
    assert_equal "N", five.fetch(:alcohol).fetch(:result)
  end

  def test_save_screening_named_screening_omitted_provider_and_comment_are_sent_blank
    screenings = { depression: { result: "P" } }
    wire = screening_wire(screenings)
    seed_screening_success(wire, screenings, post_overrides: { "1405" => "P", "1406" => "", "1701" => "" })

    wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)

    pieces = screening_call[:params].first.split("|", -1)
    assert_equal "POSITIVE", pieces[4]
    assert_equal "", pieces[5]
    assert_equal "", pieces[11]
  end

  # --- save_screening pre-call refusals --------------------------------------

  def test_save_screening_refuses_empty_screenings_without_rpc
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: {})
    end
    refute_empty err.message
    assert_empty screening_calls
  end

  def test_save_screening_refuses_unknown_screening_key_without_rpc
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT,
                              screenings: { tobacco: { result: "N" } })
    end
    assert_empty screening_calls
  end

  def test_save_screening_refuses_unknown_result_code_without_rpc
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT,
                              screenings: { depression: { result: "ZZ" } })
    end
    assert_empty screening_calls
  end

  def test_save_screening_refuses_non_positive_record_ien_or_patient_or_provider_without_rpc
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    ok = { depression: { result: "P", provider: PROVIDER, comment: "Ok note here" } }
    [
      { record_ien: "0", patient: PATIENT, screenings: ok },
      { record_ien: "-1", patient: PATIENT, screenings: ok },
      { record_ien: RECORD_IEN, patient: "0", screenings: ok },
      { record_ien: RECORD_IEN, patient: PATIENT,
        screenings: { depression: { result: "P", provider: "0", comment: "Ok note here" } } }
    ].each do |kwargs|
      assert_raises(save_error_class) { wellness.save_screening(**kwargs) }
    end
    assert_empty screening_calls
  end

  def test_save_screening_refuses_comment_shorter_than_two_or_longer_than_245_without_rpc
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT,
                              screenings: { depression: { result: "P", comment: "x" } })
    end
    long = "x" * 246
    assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT,
                              screenings: { depression: { result: "P", comment: long } })
    end
    assert_empty screening_calls
  end

  def test_save_screening_refuses_pipe_caret_or_control_in_comment_without_rpc_and_without_phi_in_message
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    [ "|", "^", "\n", RS ].each do |bad|
      err = assert_raises(save_error_class) do
        wellness.save_screening(
          RECORD_IEN, patient: PATIENT,
          screenings: { depression: { result: "P", comment: "ab#{bad}cd" } }
        )
      end
      refute_includes err.message, PHI_COMMENT
      refute_includes err.message, "ab#{bad}cd"
    end
    assert_empty screening_calls
  end

  def test_save_screening_refuses_when_pre_edit_record_missing_or_errors_without_rpc
    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT,
                              screenings: { depression: { result: "P", comment: "Ok note here" } })
    end
    refute_empty err.message
    assert_empty screening_calls

    seed_pre_edit_screening(RECORD_IEN, PATIENT, error: true)
    assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT,
                              screenings: { depression: { result: "P", comment: "Ok note here" } })
    end
    assert_empty screening_calls
  end

  def test_save_screening_refuses_patient_mismatch_without_rpc
    seed_pre_edit_screening(RECORD_IEN, OTHER_PATIENT)
    assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT,
                              screenings: { depression: { result: "P", comment: "Ok note here" } })
    end
    assert_empty screening_calls
  end

  def test_save_screening_refuses_signed_record_without_rpc
    seed_pre_edit_screening(RECORD_IEN, PATIENT, signed: true)
    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT,
                              screenings: { depression: { result: "P", comment: "Ok note here" } })
    end
    assert_match(/signed/i, err.message)
    assert_empty screening_calls
  end

  # --- save_screening post-call failures -------------------------------------

  def test_save_screening_raises_on_edit_screening_error_reply
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_screening_reply(wire, "0~Edit Screening#{RS}#{US}")

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/may have been filed/i, err.message)
    refute_includes err.message, SYNTH_DEPRESSION_COMMENT
  end

  def test_save_screening_raises_when_reply_record_ien_differs
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_screening_reply(wire, screening_success_body("9999"))

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/may have been filed/i, err.message)
  end

  def test_save_screening_raises_on_rpc_m_error_after_call
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_screening_reply(wire, screening_success_body(RECORD_IEN))
    wrapper = RpcMErrorOnWellness.new(@mock, RPC_SCREENING)
    RpmsRpc.configure { |c| c.client = wrapper }

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/may have been filed/i, err.message)
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_screening_raises_on_timeout_after_call
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_screening_reply(wire, screening_success_body(RECORD_IEN))
    wrapper = TimeoutOnWellness.new(@mock, RPC_SCREENING)
    RpmsRpc.configure { |c| c.client = wrapper }

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/may have been filed/i, err.message)
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_screening_raises_when_post_readback_does_not_match_sent_values
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_screening_reply(wire, screening_success_body(RECORD_IEN))
    seed_post_edit_screening(RECORD_IEN, PATIENT, BASELINE_INTERNAL.merge("1405" => "N"))

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/may have been filed/i, err.message)
  end

  # --- save_measurements wire + success --------------------------------------

  def test_save_measurements_pins_exact_wire_with_mode_a_never_e
    measurements = [
      { type: "PHQ9", value: 14, provider: PROVIDER },
      { type: "GAD7", value: 9, provider: PROVIDER }
    ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}*GAD7~~9~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)

    wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)

    call = measurements_call
    refute_nil call
    assert_equal RPC_MEASUREMENTS, call[:rpc]
    assert_equal wire, call[:params].first
    refute_equal "E", call[:params].first.split("|", -1)[0]
  end

  def test_save_measurements_success_returns_all_msr_rows_from_readback
    measurements = [
      { type: "PHQ9", value: 14, provider: PROVIDER },
      { type: "GAD7", value: 9, provider: PROVIDER }
    ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}*GAD7~~9~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)

    rows = wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)

    assert_equal 2, rows.length
    phq = rows.find { |r| r[:type] == "PHQ9" }
    gad = rows.find { |r| r[:type] == "GAD7" }
    refute_nil phq
    refute_nil gad
    assert_equal 14, phq[:value]
    assert_equal 9, gad[:value]
    assert_equal PROVIDER, phq.dig(:provider, :ien)
    assert_equal PROVIDER, gad.dig(:provider, :ien)
  end

  # --- save_measurements pre-call refusals -----------------------------------

  def test_save_measurements_refuses_empty_list_without_rpc
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: [])
    end
    assert_empty measurements_calls
  end

  def test_save_measurements_refuses_unknown_type_duplicate_or_out_of_range_without_rpc
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    base = { type: "PHQ9", value: 14, provider: PROVIDER }
    assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: [ base.merge(type: "BOGUS") ])
    end
    assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: [ base, base ])
    end
    [ 28, -1, "14.5", "1e1", 22 ].each do |bad|
      assert_raises(save_error_class) do
        type = bad == 22 ? "GAD7" : "PHQ9"
        wellness.save_measurements(RECORD_IEN, patient: PATIENT,
                                     measurements: [ { type: type, value: bad, provider: PROVIDER } ])
      end
    end
    assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT,
                                   measurements: [ { type: "PHQ9", value: 10, provider: nil } ])
    end
    assert_empty measurements_calls
  end

  def test_save_measurements_refuses_signed_record_without_rpc
    seed_pre_edit_screening(RECORD_IEN, PATIENT, signed: true)
    assert_raises(save_error_class) do
      wellness.save_measurements(
        RECORD_IEN, patient: PATIENT,
        measurements: [ { type: "PHQ9", value: 10, provider: PROVIDER } ]
      )
    end
    assert_empty measurements_calls
  end

  # --- save_measurements post-call failures ----------------------------------

  def test_save_measurements_raises_on_add_or_edit_measurement_error_reply
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_measurements_reply(wire, "0~Add Measurement#{RS}#{US}")

    err = assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    assert_match(/may have been filed/i, err.message)

    seed_measurements_reply(wire, "0~Edit Measurement#{RS}#{US}")
    err = assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    assert_match(/may have been filed/i, err.message)
  end

  def test_save_measurements_raises_when_readback_missing_sent_type
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_measurements_reply(wire, measurements_success_body(RECORD_IEN))
    seed_msr_read(RECORD_IEN, [])

    err = assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    assert_match(/may have been filed/i, err.message)
  end

  private

  def screening_call
    @mock.received_calls.find { |c| c[:rpc] == RPC_SCREENING }
  end

  def screening_calls
    @mock.received_calls.select { |c| c[:rpc] == RPC_SCREENING }
  end

  def measurements_call
    @mock.received_calls.find { |c| c[:rpc] == RPC_MEASUREMENTS }
  end

  def measurements_calls
    @mock.received_calls.select { |c| c[:rpc] == RPC_MEASUREMENTS }
  end

  def ddr_key(file:, iens:, fields:, flags:)
    Ddr.gets_entry_param(file: file, iens: iens, fields: fields, flags: flags).to_s
  end

  def screening_success_body(rec)
    "T00030Result#{RS}#{rec}#{RS}#{US}"
  end

  def measurements_success_body(rec)
    "T00030Result#{RS}#{rec}#{RS}#{US}"
  end

  def external_for(field_internal, code)
    key = {
      "1403" => :alcohol, "1405" => :depression, "1401" => :ipv,
      "1407" => :suicide_risk, "1409" => :suicide_screening
    }.fetch(field_internal)
    SCREENING_EXTERNAL.fetch(key).fetch(code.to_s)
  end

  def screening_wire(updates)
    merged = baseline_screening_pieces
    apply_screening_updates!(merged, updates)
    merged.join("|")
  end

  def baseline_screening_pieces
    b = BASELINE_INTERNAL
    [
      "E", RECORD_IEN,
      external_for("1403", b.fetch("1403")), b.fetch("1601"),
      external_for("1405", b.fetch("1405")), b.fetch("1701"),
      external_for("1401", b.fetch("1401")), b.fetch("1501"),
      "", "",
      b.fetch("1404"), b.fetch("1406"), b.fetch("1402"),
      external_for("1407", b.fetch("1407")), b.fetch("1901"), b.fetch("1408"),
      external_for("1409", b.fetch("1409")), b.fetch("2001"), b.fetch("1410")
    ]
  end

  def apply_screening_updates!(pieces, updates)
    updates.each do |name, attrs|
      case name
      when :alcohol
        pieces[2] = external_for("1403", attrs.fetch(:result))
        pieces[3] = attrs.key?(:comment) ? attrs[:comment].to_s : ""
        pieces[10] = attrs.key?(:provider) ? attrs[:provider].to_s : ""
      when :depression
        pieces[4] = external_for("1405", attrs.fetch(:result))
        pieces[5] = attrs.key?(:comment) ? attrs[:comment].to_s : ""
        pieces[11] = attrs.key?(:provider) ? attrs[:provider].to_s : ""
      when :ipv
        pieces[6] = external_for("1401", attrs.fetch(:result))
        pieces[7] = attrs.key?(:comment) ? attrs[:comment].to_s : ""
        pieces[12] = attrs.key?(:provider) ? attrs[:provider].to_s : ""
      when :suicide_risk
        pieces[13] = external_for("1407", attrs.fetch(:result))
        pieces[14] = attrs.key?(:comment) ? attrs[:comment].to_s : ""
        pieces[15] = attrs.key?(:provider) ? attrs[:provider].to_s : ""
      when :suicide_screening
        pieces[16] = external_for("1409", attrs.fetch(:result))
        pieces[17] = attrs.key?(:comment) ? attrs[:comment].to_s : ""
        pieces[18] = attrs.key?(:provider) ? attrs[:provider].to_s : ""
      else
        raise ArgumentError, "unknown screening #{name}"
      end
    end
  end

  def pre_edit_body(ien, patient, internal:, signed: false)
    lines = [ "#{BH_VISIT_FILE}^#{ien}^.08^#{patient}^PATIENT,SYNTH" ]
    signed_at = signed ? "3251031.12" : ""
    lines << "#{BH_VISIT_FILE}^#{ien}^1112^#{signed_at}^SIGNED"
    internal.each do |field, value|
      external = if %w[1401 1403 1405 1407 1409].include?(field)
                   external_for(field, value)
                 else
                   value.to_s
                 end
      lines << "#{BH_VISIT_FILE}^#{ien}^#{field}^#{value}^#{external}"
    end
    "[Data]\n#{lines.join("\n")}"
  end

  def seed_pre_edit_screening(ien, patient, error: false, signed: false, internal: BASELINE_INTERNAL)
    key = ddr_key(file: BH_VISIT_FILE, iens: "#{ien},", fields: PRE_EDIT_FIELDS, flags: PRE_EDIT_FLAGS)
    body = error ? "[ERROR]" : pre_edit_body(ien, patient, internal: internal, signed: signed)
    @mock.seed(:ddr_gets_entry_data, key, body)
  end

  def seed_post_edit_screening(ien, patient, internal)
    key = ddr_key(file: BH_VISIT_FILE, iens: "#{ien},", fields: PRE_EDIT_FIELDS, flags: PRE_EDIT_FLAGS)
    @mock.seed(:ddr_gets_entry_data, key, pre_edit_body(ien, patient, internal: internal))
  end

  def seed_screening_reply(wire, body)
    @mock.seed_text(:wellness_spec_save_screening, wire, body)
  end

  def seed_screening_success(wire, updates, post_overrides: nil)
    post = BASELINE_INTERNAL.merge(post_overrides || {})
    apply_screening_updates_to_internal!(post, updates)
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_screening_reply(wire, screening_success_body(RECORD_IEN))
    seed_post_edit_screening(RECORD_IEN, PATIENT, post)
  end

  def apply_screening_updates_to_internal!(internal, updates)
    map = {
      alcohol: %w[1403 1601 1404],
      depression: %w[1405 1701 1406],
      ipv: %w[1401 1501 1402],
      suicide_risk: %w[1407 1901 1408],
      suicide_screening: %w[1409 2001 1410]
    }
    updates.each do |name, attrs|
      result_f, comment_f, prov_f = map.fetch(name)
      internal[result_f] = attrs.fetch(:result)
      internal[comment_f] = attrs[:comment].to_s if attrs.key?(:comment)
      internal[prov_f] = attrs[:provider].to_s if attrs.key?(:provider)
    end
  end

  def seed_measurements_reply(wire, body)
    @mock.seed_text(:wellness_spec_save_measurements, wire, body)
  end

  def seed_msr_read(rec, rows)
    body = [ MSR_HEADER + RS ] + rows.map { |r| r + RS } + [ US ]
    @mock.seed_text(:wellness_spec_visit_msr_entry, rec.to_s, body.join("\n"))
  end

  def msr_row(type_code:, value:, provider:, description: "SYNTH DESC", type_ien: "501", name: "PROVIDER,SYNTH")
    [ type_ien, type_code, description, value.to_s, provider.to_s, name ].join("^")
  end

  def seed_measurements_success(wire, measurements)
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_measurements_reply(wire, measurements_success_body(RECORD_IEN))
    seed_msr_read(
      RECORD_IEN,
      measurements.map do |m|
        msr_row(type_code: m.fetch(:type), value: m.fetch(:value), provider: m.fetch(:provider))
      end
    )
  end
end

class TimeoutOnWellness < SimpleDelegator
  def initialize(delegate, rpc_name)
    super(delegate)
    @rpc_name = rpc_name
  end

  def call_rpc_global_array(rpc_name, *params)
    result = super
    raise RpmsRpc::Client::RpcTimeoutError, "#{rpc_name} timed out (synthetic)" if rpc_name == @rpc_name

    result
  end
end

class RpcMErrorOnWellness < SimpleDelegator
  def initialize(delegate, rpc_name)
    super(delegate)
    @rpc_name = rpc_name
  end

  def call_rpc_global_array(rpc_name, *params)
    super
    raise RpmsRpc::Client::RpcMError, "#{rpc_name} M error (synthetic)" if rpc_name == @rpc_name
  end
end
