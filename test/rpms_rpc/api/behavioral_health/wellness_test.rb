# frozen_string_literal: true

require "minitest/autorun"
require "delegate"
require "json"
require "timeout"
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
  RESENT_PROVIDER = "411"
  RECORD_IEN = "8840"
  PROVIDER_FILE = "200"
  FILEMAN_CONTEXT = RpmsRpc::Patient::FILEMAN_CONTEXT
  DDR_GETS = "DDR GETS ENTRY DATA"
  DDR_LOCK = "DDR LOCK/UNLOCK NODE"

  SYNTH_DEPRESSION_COMMENT = "Synthetic depression screening note for spec"
  PHI_COMMENT = "Unique PHI marker xyzzy screening comment"

  SYNTH_WELLNESS_SESSION_ID = "SYNTH-WELLNESS-SESSION-540"

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
    @visit_gets_client = nil
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

  def test_save_screening_amhg_write_runs_under_amhgrpc_and_restores_the_callers_context
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    seed_screening_success(wire, screenings)
    caller_context = @mock.current_context

    wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)

    assert_equal "AMHGRPC", screening_call[:context]
    assert_equal caller_context, @mock.current_context
  end

  def test_save_screening_ddr_reads_and_lock_run_under_ciav_vuecentric
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    seed_screening_success(wire, screenings)
    caller_context = @mock.current_context

    wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)

    ddr_calls = @mock.received_calls.select { |c| c[:rpc] == DDR_GETS || c[:rpc] == DDR_LOCK }
    refute_empty ddr_calls
    ddr_calls.each do |call|
      assert_equal FILEMAN_CONTEXT, call[:context],
                   "#{call[:rpc]} must run under #{FILEMAN_CONTEXT.inspect}"
    end
    amh_binds = @mock.context_binds.grep("AMHGRPC")
    refute_empty amh_binds
    assert_equal caller_context, @mock.current_context
  end

  def test_save_measurements_ddr_reads_and_lock_run_under_ciav_vuecentric
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)
    caller_context = @mock.current_context

    wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)

    ddr_calls = @mock.received_calls.select { |c| c[:rpc] == DDR_GETS || c[:rpc] == DDR_LOCK }
    refute_empty ddr_calls
    ddr_calls.each do |call|
      assert_equal FILEMAN_CONTEXT, call[:context]
    end
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
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    seed_pre_edit_screening(RECORD_IEN, OTHER_PATIENT)
    seed_baseline_stored_screening_providers
    seed_provider_exists(PROVIDER)

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/patient/i, err.message)
    assert_empty screening_calls
  end

  def test_save_measurements_refuses_patient_mismatch_without_rpc
    seed_pre_edit_screening(RECORD_IEN, OTHER_PATIENT)
    seed_provider_exists(PROVIDER)

    err = assert_raises(save_error_class) do
      wellness.save_measurements(
        RECORD_IEN, patient: PATIENT,
        measurements: [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
      )
    end
    assert_match(/patient/i, err.message)
    assert_empty measurements_calls
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

  def test_save_screening_refuses_when_visit_lock_fails_without_write_rpc
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    seed_pre_edit_visit_gets(RECORD_IEN, PATIENT, BASELINE_INTERNAL)
    seed_visit_lock(RECORD_IEN, acquired: false)
    seed_provider_exists(PROVIDER)

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/lock/i, err.message)
    assert_empty screening_calls
  end

  def test_save_measurements_refuses_when_visit_lock_fails_without_write_rpc
    seed_pre_edit_visit_gets(RECORD_IEN, PATIENT, BASELINE_INTERNAL)
    seed_visit_lock(RECORD_IEN, acquired: false)
    seed_provider_exists(PROVIDER)

    assert_raises(save_error_class) do
      wellness.save_measurements(
        RECORD_IEN, patient: PATIENT,
        measurements: [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
      )
    end
    assert_empty measurements_calls
  end

  def test_save_screening_refuses_unknown_provider_without_write_rpc
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_provider_missing(PROVIDER)

    err = assert_raises(save_error_class) do
      wellness.save_screening(
        RECORD_IEN, patient: PATIENT,
        screenings: { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
      )
    end
    assert_match(/provider/i, err.message)
    assert_empty screening_calls
  end

  def test_save_measurements_refuses_unknown_provider_without_write_rpc
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_provider_missing(PROVIDER)

    err = assert_raises(save_error_class) do
      wellness.save_measurements(
        RECORD_IEN, patient: PATIENT,
        measurements: [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
      )
    end
    assert_match(/provider/i, err.message)
    assert_empty measurements_calls
  end

  def test_save_screening_revalidates_resent_provider_on_file_200
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    seed_screening_success(wire, screenings)

    wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)

    assert provider_ddr_calls(RESENT_PROVIDER).any?, "stored alcohol provider must be read on file 200"
    assert provider_ddr_calls(PROVIDER).any?, "caller-supplied provider must be verified on file 200"
    refute_nil screening_call
  end

  def test_save_screening_refuses_when_stored_provider_not_on_file_200_without_write
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_provider_exists(PROVIDER)
    seed_provider_missing(RESENT_PROVIDER)

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_empty screening_calls, "AMHG SAVE SCREENING must not run when a stored provider fails file 200 check"
    assert_match(/provider|stored screening/i, err.message)
  end

  def test_save_screening_refuses_caller_provider_when_file_200_reply_has_error_marker_without_write
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_baseline_stored_screening_providers
    seed_provider_error_with_row(PROVIDER)

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_empty screening_calls
    assert_match(/provider/i, err.message)
  end

  def test_save_screening_refuses_caller_provider_when_file_200_dot01_is_blank_without_write
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_baseline_stored_screening_providers
    seed_provider_blank_dot01(PROVIDER)

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/provider/i, err.message)
    assert_empty screening_calls
  end

  def test_save_screening_refuses_stored_result_field_missing_without_write
    internal = BASELINE_INTERNAL.dup
    internal.delete("1403")
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    seed_pre_edit_screening(RECORD_IEN, PATIENT, internal: internal)
    seed_baseline_stored_screening_providers
    seed_provider_exists(PROVIDER)

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/stored screening cannot be resent/i, err.message)
    assert_empty screening_calls
  end

  def test_save_screening_refuses_stored_result_code_not_filed_without_write
    internal = BASELINE_INTERNAL.merge("1403" => "ZZ")
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    seed_pre_edit_screening(RECORD_IEN, PATIENT, internal: internal)
    seed_baseline_stored_screening_providers
    seed_provider_exists(PROVIDER)

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/stored screening cannot be resent/i, err.message)
    assert_empty screening_calls
  end

  def test_save_screening_refuses_stored_comment_field_missing_without_write
    internal = BASELINE_INTERNAL.dup
    internal.delete("1601")
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    seed_pre_edit_screening(RECORD_IEN, PATIENT, internal: internal)
    seed_baseline_stored_screening_providers
    seed_provider_exists(PROVIDER)

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/stored screening cannot be resent/i, err.message)
    assert_empty screening_calls
  end

  def test_save_screening_refuses_stored_provider_field_missing_without_write
    internal = BASELINE_INTERNAL.dup
    internal.delete("1404")
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    seed_pre_edit_screening(RECORD_IEN, PATIENT, internal: internal)
    seed_baseline_stored_screening_providers
    seed_provider_exists(PROVIDER)

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/stored screening cannot be resent/i, err.message)
    assert_empty screening_calls
  end

  def test_save_screening_reads_each_distinct_stored_provider_on_file_200_once
    internal = BASELINE_INTERNAL.merge(
      "1402" => RESENT_PROVIDER, "1404" => RESENT_PROVIDER, "1406" => RESENT_PROVIDER,
      "1408" => RESENT_PROVIDER, "1410" => RESENT_PROVIDER
    )
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings, internal: internal)
    post = internal.dup
    apply_screening_updates_to_internal!(post, screenings)
    seed_visit_lock(RECORD_IEN)
    seed_visit_unlock(RECORD_IEN)
    seed_providers_for_screening_updates(screenings)
    seed_provider_exists(RESENT_PROVIDER)
    install_visit_gets_sequence(RECORD_IEN, PATIENT, internal, post)
    seed_screening_reply(wire, screening_success_body(RECORD_IEN))

    wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)

    assert_equal 1, provider_ddr_calls(RESENT_PROVIDER).length,
                 "each distinct stored provider IEN must be verified on file 200 once"
    assert_equal 1, provider_ddr_calls(PROVIDER).length
  end

  def test_save_screening_refuses_stored_comment_with_replacement_character_without_write
    bad = BASELINE_INTERNAL.merge("1601" => "Alcohol note \uFFFD unreadable")
    seed_pre_edit_screening(RECORD_IEN, PATIENT, internal: bad)
    seed_provider_exists(PROVIDER)

    err = assert_raises(save_error_class) do
      wellness.save_screening(
        RECORD_IEN, patient: PATIENT,
        screenings: { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
      )
    end
    assert_match(/stored screening cannot be resent/i, err.message)
    assert_empty screening_calls
  end

  def test_save_screening_unlocks_visit_after_success
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    seed_screening_success(wire, screenings)

    wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)

    assert_equal 1, lock_calls_for(RECORD_IEN).length
    assert_equal 1, unlock_calls_for(RECORD_IEN).length
  end

  def test_save_screening_unlocks_visit_when_readback_raises_save_error
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    post = BASELINE_INTERNAL.merge("1405" => "N")
    seed_screening_flow(wire, screenings, post_internal: post)

    assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_equal 1, unlock_calls_for(RECORD_IEN).length
    refute_nil screening_call
  end

  def test_save_screening_unlock_failure_does_not_change_success
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    seed_screening_success(wire, screenings)
    seed_visit_unlock(RECORD_IEN, success: false)

    result = wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)

    assert_equal RECORD_IEN, result.fetch(:record_ien)
    assert_equal 1, unlock_calls_for(RECORD_IEN).length
  end

  def test_save_screening_success_survives_unlock_raising_standard_error
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    seed_screening_success(wire, screenings)
    wrapper = UnlockRaiseClient.new(visit_gets_client, NoMethodError, "unlock blew up (synthetic)")
    RpmsRpc.configure { |c| c.client = wrapper }

    result = wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)

    assert_equal RECORD_IEN, result.fetch(:record_ien)
    assert_equal 1, wrapper.unlock_refusal_count,
                 "visit unlock must be attempted exactly once on the captured client"
    assert_empty unlock_calls_for(RECORD_IEN), "unlock must not be retried on the inner session client"
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_screening_save_error_survives_unlock_raising_not_implemented_error
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    post = BASELINE_INTERNAL.merge("1405" => "N")
    seed_screening_flow(wire, screenings, post_internal: post)
    wrapper = UnlockRaiseClient.new(visit_gets_client, NotImplementedError, "unlock blew up (synthetic)")
    RpmsRpc.configure { |c| c.client = wrapper }

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/may have been filed/i, err.message)
    assert_equal 1, wrapper.unlock_refusal_count,
                 "visit unlock must be attempted exactly once on the captured client"
    assert_empty unlock_calls_for(RECORD_IEN), "unlock must not be retried on the inner session client"
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_screening_inner_receives_no_unlock_when_wrapper_refuses_unlock_after_readback
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    seed_screening_success(wire, screenings)
    inner = InnerUnlockForbiddenClient.new(visit_gets_client)
    wrapper = PostScreeningWriteUnlockRefuseClient.new(inner)
    RpmsRpc.configure { |c| c.client = wrapper }

    result = wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)

    assert_equal RECORD_IEN, result.fetch(:record_ien)
    assert_equal 1, wrapper.unlock_refusals.length,
                 "wrapper must receive and refuse exactly one unlock after readback"
    assert_empty inner.unlock_attempts,
                 "inner client must not receive unlock RPC when wrapper already refused unlock"
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_screening_unlocks_after_lock_rpc_timeout_before_refusing
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_provider_exists(PROVIDER)
    wrapper = LockRpcTimeoutClient.new(@mock, RECORD_IEN)
    RpmsRpc.configure { |c| c.client = wrapper }

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/lock/i, err.message)
    assert_empty screening_calls
    assert_equal 1, unlock_calls_for(RECORD_IEN).length,
                 "unlock must run when the lock RPC fails even though nothing was written"
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_unlocks_after_lock_returns_false_before_refusing
    seed_pre_edit_visit_gets(RECORD_IEN, PATIENT, BASELINE_INTERNAL)
    seed_visit_lock(RECORD_IEN, acquired: false)
    seed_provider_exists(PROVIDER)

    err = assert_raises(save_error_class) do
      wellness.save_measurements(
        RECORD_IEN, patient: PATIENT,
        measurements: [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
      )
    end
    assert_match(/lock/i, err.message)
    assert_empty measurements_calls
    assert_equal 1, unlock_calls_for(RECORD_IEN).length,
                 "unlock must run when the lock is refused even though nothing was written"
  end

  def test_save_screening_refuses_reentrant_save_for_same_client_and_record_without_rpc
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    inner_measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    seed_screening_success(wire, screenings)
    wrapper = ReentrantWellnessSaveClient.new(
      visit_gets_client, wellness,
      record_ien: RECORD_IEN, patient: PATIENT,
      trigger_rpc: RPC_SCREENING
    ) do |w|
      w.save_measurements(RECORD_IEN, patient: PATIENT, measurements: inner_measurements)
    end
    RpmsRpc.configure { |c| c.client = wrapper }

    wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)

    refute_nil wrapper.inner_error
    assert_instance_of save_error_class, wrapper.inner_error
    assert_match(/in progress/i, wrapper.inner_error.message)
    assert_equal wrapper.rpc_count_before_reentry, wrapper.rpc_count_after_reentry,
                 "reentrant save must not send any RPC"
    assert_equal wrapper.measurements_rpc_before_reentry, wrapper.measurements_rpc_after_reentry
    assert_equal 1, screening_calls.length
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_allows_save_for_different_record_while_same_client_busy
    other = "8841"
    outer_measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    inner_measurements = [ { type: "GAD7", value: 9, provider: PROVIDER } ]
    outer_wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    inner_wire = "A|#{other}|GAD7~~9~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(outer_wire, outer_measurements)
    seed_measurements_success(inner_wire, inner_measurements, record_ien: other)
    wrapper = ReentrantWellnessSaveClient.new(
      visit_gets_client, wellness,
      record_ien: RECORD_IEN, patient: PATIENT,
      trigger_rpc: RPC_MEASUREMENTS
    ) do |w|
      w.save_measurements(other, patient: PATIENT, measurements: inner_measurements)
    end
    RpmsRpc.configure { |c| c.client = wrapper }

    wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: outer_measurements)

    assert_nil wrapper.inner_error, "inner save for a different record must succeed"
    assert_equal 1, @mock.received_calls.count { |c| c[:rpc] == RPC_MEASUREMENTS && c[:params]&.first.to_s.include?(other) },
                 "inner save must send its write RPC"
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_refuses_reentrant_save_for_same_record_via_second_wrapper_on_same_client
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)
    base = WellnessSessionClient.new(visit_gets_client, SYNTH_WELLNESS_SESSION_ID)
    wrapper_b = SimpleDelegator.new(base)
    wrapper_a = DualWrapperReentrantMeasurementsClient.new(
      base, wrapper_b, wellness, record_ien: RECORD_IEN, patient: PATIENT
    ) do |w|
      w.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    RpmsRpc.configure { |c| c.client = wrapper_a }

    wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)

    refute_nil wrapper_a.inner_error
    assert_instance_of save_error_class, wrapper_a.inner_error
    assert_match(/in progress/i, wrapper_a.inner_error.message)
    assert_equal wrapper_a.rpc_count_before_reentry, wrapper_a.rpc_count_after_reentry,
                 "reentrant inner save must not send any RPC"
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_two_wrappers_without_session_id_do_not_share_in_progress_guard
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)
    base = visit_gets_client
    wrapper_b = SimpleDelegator.new(base)
    wrapper_a = DualWrapperReentrantMeasurementsClient.new(
      base, wrapper_b, wellness, record_ien: RECORD_IEN, patient: PATIENT
    ) do |w|
      w.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    RpmsRpc.configure { |c| c.client = wrapper_a }

    wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)

    assert_nil wrapper_a.inner_error, "inner save must succeed when guards are not shared"
    save_rpc_calls = @mock.received_calls.select { |c| c[:rpc] == RPC_MEASUREMENTS }
    assert_equal 2, save_rpc_calls.length,
                 "reentrant harness runs inner save during outer write then outer write; " \
                 "distinct guards must produce two AMHG SAVE MEASUREMENTS calls"
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_forwarding_wrapper_with_session_id_cannot_evade_in_progress_guard
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)
    base = WellnessSessionClient.new(visit_gets_client, SYNTH_WELLNESS_SESSION_ID)
    inner_forwarder = ForwardingWellnessClient.new(base)
    wrapper_a = DualWrapperReentrantMeasurementsClient.new(
      base, inner_forwarder, wellness, record_ien: RECORD_IEN, patient: PATIENT
    ) do |w|
      w.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    RpmsRpc.configure { |c| c.client = wrapper_a }

    wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)

    refute_nil wrapper_a.inner_error
    assert_match(/in progress/i, wrapper_a.inner_error.message)
    assert_equal wrapper_a.rpc_count_before_reentry, wrapper_a.rpc_count_after_reentry
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_same_session_id_on_distinct_clients_shares_in_progress_guard
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)
    base = visit_gets_client
    client_a = WellnessSessionClient.new(base, SYNTH_WELLNESS_SESSION_ID)
    client_b = WellnessSessionClient.new(base, SYNTH_WELLNESS_SESSION_ID)
    wrapper = CrossClientReentrantMeasurementsClient.new(
      client_a, client_b, wellness, record_ien: RECORD_IEN, patient: PATIENT, measurements: measurements
    )
    RpmsRpc.configure { |c| c.client = wrapper }

    wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)

    refute_nil wrapper.inner_error
    assert_match(/in progress/i, wrapper.inner_error.message)
    assert_equal wrapper.rpc_count_before_reentry, wrapper.rpc_count_after_reentry
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_different_session_id_on_distinct_clients_do_not_share_guard
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)
    base = visit_gets_client
    client_a = WellnessSessionClient.new(base, "SYNTH-SESSION-A-540")
    client_b = WellnessSessionClient.new(base, "SYNTH-SESSION-B-540")
    wrapper = CrossClientReentrantMeasurementsClient.new(
      client_a, client_b, wellness, record_ien: RECORD_IEN, patient: PATIENT, measurements: measurements
    )
    RpmsRpc.configure { |c| c.client = wrapper }

    wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)

    assert_nil wrapper.inner_error, "inner save must succeed when session guards differ"
    assert_equal 2, @mock.received_calls.count { |c| c[:rpc] == RPC_MEASUREMENTS },
                 "reentrant harness runs inner save during outer write then outer write; " \
                 "distinct session guards must produce two AMHG SAVE MEASUREMENTS calls"
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_screening_raises_save_error_when_session_id_raises_before_any_rpc
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_baseline_stored_screening_providers
    seed_provider_exists(PROVIDER)
    wrapper = SessionIdRaiseClient.new(visit_gets_client, RuntimeError, "session_id blew up (synthetic)")
    RpmsRpc.configure { |c| c.client = wrapper }

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/session/i, err.message)
    assert_empty screening_calls
    assert_empty measurements_calls
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_calls_session_id_exactly_once_per_save
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)
    counter = SessionIdCallCountClient.new(visit_gets_client, SYNTH_WELLNESS_SESSION_ID)
    RpmsRpc.configure { |c| c.client = counter }

    wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)

    assert_equal 1, counter.session_id_calls, "session_id must be read at most once per save"
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_session_id_equal_to_other_client_object_id_does_not_share_guard
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)
    base = visit_gets_client
    outer = SimpleDelegator.new(base)
    inner = WellnessSessionClient.new(base, outer.object_id)
    wrapper = CrossClientReentrantMeasurementsClient.new(
      outer, inner, wellness, record_ien: RECORD_IEN, patient: PATIENT, measurements: measurements
    )
    RpmsRpc.configure { |c| c.client = wrapper }

    wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)

    assert_nil wrapper.inner_error,
               "session_id must not collide with another client's object_id guard key"
    assert_equal 2, @mock.received_calls.count { |c| c[:rpc] == RPC_MEASUREMENTS }
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_false_session_id_falls_back_to_object_id_for_guard
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)
    base = visit_gets_client
    wrapper_b = FalseSessionIdClient.new(base)
    wrapper_a = FalseSessionIdClient.new(base)
    reentrant = DualWrapperReentrantMeasurementsClient.new(
      wrapper_a, wrapper_b, wellness, record_ien: RECORD_IEN, patient: PATIENT
    ) do |w|
      w.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    RpmsRpc.configure { |c| c.client = reentrant }

    wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)

    assert_nil reentrant.inner_error,
               "false session_id must fall back to object_id like blank session_id"
    assert_equal 2, @mock.received_calls.count { |c| c[:rpc] == RPC_MEASUREMENTS }
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_blank_session_id_falls_back_to_object_id_for_guard
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)
    base = visit_gets_client
    wrapper_b = WellnessSessionClient.new(base, "")
    wrapper_a = WellnessSessionClient.new(base, "")
    reentrant = DualWrapperReentrantMeasurementsClient.new(
      wrapper_a, wrapper_b, wellness, record_ien: RECORD_IEN, patient: PATIENT
    ) do |w|
      w.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    RpmsRpc.configure { |c| c.client = reentrant }

    wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)

    assert_nil reentrant.inner_error,
               "inner save must succeed when blank session_id falls back to distinct object_id guards"
    assert_equal 2, @mock.received_calls.count { |c| c[:rpc] == RPC_MEASUREMENTS },
                 "reentrant harness runs inner save during outer write then outer write; " \
                 "object_id guards on distinct clients must produce two AMHG SAVE MEASUREMENTS calls"
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_nil_session_id_same_client_object_reentry_still_refused
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)
    base = NilSessionIdClient.new(visit_gets_client)
    wrapper = ReentrantWellnessSaveClient.new(
      base, wellness,
      record_ien: RECORD_IEN, patient: PATIENT,
      trigger_rpc: RPC_MEASUREMENTS
    ) do |w|
      w.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    RpmsRpc.configure { |c| c.client = wrapper }

    wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)

    refute_nil wrapper.inner_error
    assert_match(/in progress/i, wrapper.inner_error.message)
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_wellness_implementation_does_not_use_delegate_unwrap_or_unlock_through_delegate
    source = File.read(File.join(ROOT, "lib/rpms_rpc/api/behavioral_health/wellness.rb"))

    refute_includes source, "__getobj__"
    refute_includes source, "unlock_through_delegate"
  end

  def test_save_measurements_concurrent_same_record_second_refused_until_first_completes
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)
    release = Queue.new
    entered = Queue.new
    blocker = BlockOnMeasurementsWriteClient.new(
      visit_gets_client, entered: entered, release: release, record_ien: RECORD_IEN
    )
    RpmsRpc.configure { |c| c.client = blocker }

    worker = Thread.new do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end

    entered.pop(timeout: 5) || flunk("timed out waiting for write RPC to start")

    write_rpc_count = @mock.received_calls.count { |c| c[:rpc] == RPC_MEASUREMENTS }
    err = assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    assert_match(/in progress/i, err.message)
    assert_equal write_rpc_count,
                 @mock.received_calls.count { |c| c[:rpc] == RPC_MEASUREMENTS },
                 "concurrent save must not send another write RPC"

    release.push(true)
    worker.join(5) || flunk("timed out waiting for first save to finish")
    refute worker.alive?, "first concurrent save must complete"
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_concurrent_different_records_both_succeed
    other = "8841"
    outer = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    inner = [ { type: "GAD7", value: 9, provider: PROVIDER } ]
    outer_wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    inner_wire = "A|#{other}|GAD7~~9~#{PROVIDER}|#{PATIENT}"
    seed_concurrent_measurements_success(outer_wire, outer, RECORD_IEN)
    seed_concurrent_measurements_success(inner_wire, inner, other)
    release = Queue.new
    entered = Queue.new
    blocker = BlockOnMeasurementsWriteClient.new(
      @mock, entered: entered, release: release, record_ien: RECORD_IEN
    )
    RpmsRpc.configure { |c| c.client = blocker }

    outer_rows = nil
    worker = Thread.new do
      outer_rows = wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: outer)
    end

    entered.pop(timeout: 5) || flunk("timed out waiting for outer write RPC to start")

    inner_rows = wellness.save_measurements(other, patient: PATIENT, measurements: inner)

    assert_equal 1,
                 @mock.received_calls.count { |c|
                   c[:rpc] == RPC_MEASUREMENTS && c[:params]&.first.to_s.include?("|#{other}|")
                 },
                 "inner save for a different record must send its write RPC while outer save is blocked"
    refute_nil inner_rows
    assert_equal "GAD7", inner_rows.find { |r| r[:type] == "GAD7" }&.fetch(:type)

    release.push(true)
    worker.join(5) || flunk("timed out waiting for outer save")
    refute worker.alive?, "outer concurrent save must complete"
    refute_nil outer_rows
    assert_equal "PHQ9", outer_rows.find { |r| r[:type] == "PHQ9" }&.fetch(:type)
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_uses_client_captured_at_start_when_configuration_changes_mid_save
    other = RpmsRpc::MockClient.new
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)
    swapper = SwapClientOnLockAcquireClient.new(visit_gets_client, other, RECORD_IEN)
    RpmsRpc.configure { |c| c.client = swapper }

    wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)

    assert swapper.swapped?, "mid-save client swap must have run"
    assert_empty other.received_calls, "RPCs must not reach the client installed mid-save"
    assert_equal 1, measurements_calls.length
    assert_equal 1, unlock_calls_for(RECORD_IEN).length
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_raises_save_error_not_argument_error_when_lock_raises_after_rpc_sent
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    seed_pre_edit_visit_gets(RECORD_IEN, PATIENT, BASELINE_INTERNAL)
    seed_visit_lock(RECORD_IEN)
    seed_provider_exists(PROVIDER)
    reseed = VisitGetsReseedClient.new(@mock, visit_ddr_key(RECORD_IEN), [])
    wrapper = LockArgumentErrorAfterSendClient.new(reseed, RECORD_IEN)
    RpmsRpc.configure { |c| c.client = wrapper }

    err = assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    refute_instance_of ArgumentError, err.class
    assert_match(/lock/i, err.message)
    assert_equal 1, unlock_calls_for(RECORD_IEN).length
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_raises_save_error_on_timeout_error_during_amhg_write
    assert_non_gem_standard_error_during_save_raises_save_error(
      AfterWriteRpcErrorClient.new(visit_gets_client, RPC_MEASUREMENTS, ::Timeout::Error,
                                   "AMHG write hung (synthetic)", require_write_first: false)
    )
  end

  def test_save_measurements_raises_save_error_on_timeout_error_during_post_write_visit_read
    assert_non_gem_standard_error_during_save_raises_save_error(
      PostWriteVisitReadErrorClient.new(visit_gets_client, ::Timeout::Error, "post-write visit read (synthetic)")
    )
  end

  def test_save_measurements_raises_save_error_on_timeout_error_during_msr_read_back
    assert_non_gem_standard_error_during_save_raises_save_error(
      AfterWriteRpcErrorClient.new(visit_gets_client, RPC_MSR_READ, ::Timeout::Error,
                                   "MSR read-back hung (synthetic)", require_write_first: true)
    )
  end

  def test_save_screening_raises_save_error_not_ioerror_when_provider_ddr_gets_raises_ioerror
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    seed_pre_edit_screening(RECORD_IEN, PATIENT)
    seed_baseline_stored_screening_providers
    seed_visit_unlock(RECORD_IEN)
    message = "file 200 provider DDR GETS failed (synthetic)"
    wrapper = DdrGetsIOErrorOnMatchClient.new(
      @mock, ->(param) { provider_ddr_param?(param) }, message
    )
    RpmsRpc.configure { |c| c.client = wrapper }

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_instance_of IOError, err.cause
    assert_equal message, err.cause.message
    assert_empty screening_calls
    assert_equal 1, unlock_calls_for(RECORD_IEN).length
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_measurements_raises_save_error_not_ioerror_when_provider_ddr_gets_raises_ioerror
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    seed_pre_edit_visit_gets(RECORD_IEN, PATIENT, BASELINE_INTERNAL)
    seed_visit_unlock(RECORD_IEN)
    message = "file 200 provider DDR GETS failed (synthetic)"
    wrapper = DdrGetsIOErrorOnMatchClient.new(
      @mock, ->(param) { provider_ddr_param?(param) }, message
    )
    RpmsRpc.configure { |c| c.client = wrapper }

    err = assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    assert_instance_of IOError, err.cause
    assert_equal message, err.cause.message
    assert_empty measurements_calls
    assert_equal 1, unlock_calls_for(RECORD_IEN).length
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_screening_raises_save_error_not_ioerror_when_pre_write_visit_ddr_gets_raises_ioerror
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    seed_visit_lock(RECORD_IEN)
    seed_visit_unlock(RECORD_IEN)
    message = "pre-write visit DDR GETS failed (synthetic)"
    wrapper = DdrGetsIOErrorOnMatchClient.new(
      @mock, ->(param) { visit_ddr_param?(RECORD_IEN, param) }, message
    )
    RpmsRpc.configure { |c| c.client = wrapper }

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_instance_of IOError, err.cause
    assert_equal message, err.cause.message
    assert_empty screening_calls
    assert_equal 1, unlock_calls_for(RECORD_IEN).length
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_screening_second_call_for_same_record_after_first_succeeds
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    2.times do
      seed_screening_success(wire, screenings)
      result = wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
      assert_equal RECORD_IEN, result.fetch(:record_ien)
    end
  end

  # --- save_screening post-call failures -------------------------------------

  def test_save_screening_raises_on_edit_screening_error_reply
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    post = BASELINE_INTERNAL.dup
    apply_screening_updates_to_internal!(post, screenings)
    seed_screening_flow(wire, screenings, post_internal: post, reply: "0~Edit Screening#{RS}#{US}")

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/may have been filed/i, err.message)
    refute_includes err.message, SYNTH_DEPRESSION_COMMENT
  end

  def test_save_screening_raises_when_reply_record_ien_differs
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    post = BASELINE_INTERNAL.dup
    apply_screening_updates_to_internal!(post, screenings)
    seed_screening_flow(wire, screenings, post_internal: post, reply: screening_success_body("9999"))

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/may have been filed/i, err.message)
  end

  def test_save_screening_raises_on_rpc_m_error_after_call
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    post = BASELINE_INTERNAL.dup
    apply_screening_updates_to_internal!(post, screenings)
    seed_screening_flow(wire, screenings, post_internal: post)
    wrapper = RpcMErrorOnWellness.new(visit_gets_client, RPC_SCREENING)
    RpmsRpc.configure { |c| c.client = wrapper }

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/may have been filed/i, err.message)
    assert_equal 1, unlock_calls_for(RECORD_IEN).length
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_screening_raises_on_timeout_after_call
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    post = BASELINE_INTERNAL.dup
    apply_screening_updates_to_internal!(post, screenings)
    seed_screening_flow(wire, screenings, post_internal: post)
    wrapper = TimeoutOnWellness.new(visit_gets_client, RPC_SCREENING)
    RpmsRpc.configure { |c| c.client = wrapper }

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/may have been filed/i, err.message)
    assert_equal 1, unlock_calls_for(RECORD_IEN).length
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_save_screening_raises_when_post_readback_does_not_match_sent_values
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    post = BASELINE_INTERNAL.merge("1405" => "N")
    seed_screening_flow(wire, screenings, post_internal: post)

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/may have been filed/i, err.message)
  end

  def test_save_screening_raises_when_post_readback_comment_does_not_match_sent_values
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    post = BASELINE_INTERNAL.dup
    apply_screening_updates_to_internal!(post, screenings)
    post["1701"] = "Different comment on read-back"
    seed_screening_flow(wire, screenings, post_internal: post)

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/may have been filed/i, err.message)
    refute_nil screening_call
  end

  def test_save_screening_raises_when_post_readback_provider_does_not_match_sent_values
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    post = BASELINE_INTERNAL.dup
    apply_screening_updates_to_internal!(post, screenings)
    post["1406"] = "999"
    seed_screening_flow(wire, screenings, post_internal: post)

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/may have been filed/i, err.message)
    refute_nil screening_call
  end

  def test_save_measurements_raises_when_post_visit_read_omits_1112_after_write
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    row = [ msr_row(type_code: "PHQ9", value: 14, provider: PROVIDER) ]
    seed_visit_lock(RECORD_IEN)
    seed_visit_unlock(RECORD_IEN)
    seed_providers_for_measurements(measurements)
    post_internal = BASELINE_INTERNAL.dup
    install_visit_gets_sequence(
      RECORD_IEN, PATIENT, BASELINE_INTERNAL, post_internal, include_post_1112: false
    )
    seed_measurements_reply(wire, measurements_success_body(RECORD_IEN))
    seed_msr_read(RECORD_IEN, row)

    err = assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    assert_match(/may have been filed/i, err.message)
    refute_nil measurements_call
  end

  def test_save_screening_raises_when_post_readback_omits_a_filed_screening_field
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings)
    post = BASELINE_INTERNAL.dup
    apply_screening_updates_to_internal!(post, screenings)
    post.delete("1404")
    seed_screening_flow(wire, screenings, post_internal: post)

    err = assert_raises(save_error_class) do
      wellness.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings)
    end
    assert_match(/may have been filed/i, err.message)
    refute_nil screening_call
  end

  def test_save_screening_raises_when_post_readback_omits_provider_field_even_if_expected_blank
    baseline = BASELINE_INTERNAL.merge("1404" => "")
    screenings = { depression: { result: "P", provider: PROVIDER, comment: SYNTH_DEPRESSION_COMMENT } }
    wire = screening_wire(screenings, internal: baseline)
    post = baseline.dup
    apply_screening_updates_to_internal!(post, screenings)
    post.delete("1404")
    seed_visit_lock(RECORD_IEN)
    seed_visit_unlock(RECORD_IEN)
    seed_providers_for_screening_updates(screenings)
    seed_baseline_stored_screening_providers
    install_visit_gets_sequence(RECORD_IEN, PATIENT, baseline, post)
    seed_screening_reply(wire, screening_success_body(RECORD_IEN))

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
    row = [ msr_row(type_code: "PHQ9", value: 14, provider: PROVIDER) ]
    seed_measurements_flow(wire, measurements, msr_rows: row, reply: "0~Add Measurement#{RS}#{US}")

    err = assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    assert_match(/may have been filed/i, err.message)

    seed_measurements_flow(wire, measurements, msr_rows: row, reply: "0~Edit Measurement#{RS}#{US}")
    err = assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    assert_match(/may have been filed/i, err.message)
  end

  def test_save_measurements_raises_when_readback_missing_sent_type
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_flow(wire, measurements, msr_rows: [])

    err = assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    assert_match(/may have been filed/i, err.message)
  end

  def test_save_measurements_raises_when_post_visit_read_shows_patient_mismatch
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_flow(
      wire, measurements,
      post_patient: OTHER_PATIENT,
      msr_rows: [ msr_row(type_code: "PHQ9", value: 14, provider: PROVIDER) ]
    )

    err = assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    assert_match(/may have been filed/i, err.message)
    refute_nil measurements_call
  end

  def test_save_measurements_keeps_unsent_non_integer_measurement_as_string_value
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(
      wire, measurements,
      extra_msr_rows: [ msr_row(type_code: "WT", value: "180.5", provider: PROVIDER, type_ien: "502") ]
    )

    rows = wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)

    wt = rows.find { |r| r[:type] == "WT" }
    refute_nil wt
    assert_equal "180.5", wt[:value]
    assert_equal 14, rows.find { |r| r[:type] == "PHQ9" }[:value]
  end

  def test_save_measurements_raises_when_readback_value_differs
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_flow(
      wire, measurements,
      msr_rows: [ msr_row(type_code: "PHQ9", value: 15, provider: PROVIDER) ]
    )

    err = assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    assert_match(/may have been filed/i, err.message)
  end

  def test_save_measurements_raises_when_readback_provider_differs
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_flow(
      wire, measurements,
      msr_rows: [ msr_row(type_code: "PHQ9", value: 14, provider: "999") ]
    )

    assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
  end

  def test_save_measurements_raises_when_sent_type_appears_twice_in_readback
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    row = msr_row(type_code: "PHQ9", value: 14, provider: PROVIDER)
    seed_measurements_flow(wire, measurements, msr_rows: [ row, row ])

    assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
  end

  def test_save_measurements_raises_on_unparseable_msr_readback
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_flow(wire, measurements, msr_body: "not-a-recordset")

    assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
  end

  def test_save_measurements_unlocks_visit_after_success
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)

    wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)

    assert_equal 1, lock_calls_for(RECORD_IEN).length
    assert_equal 1, unlock_calls_for(RECORD_IEN).length
  end

  def test_save_measurements_unlock_attempted_when_write_raises_rpc_m_error
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    row = [ msr_row(type_code: "PHQ9", value: 14, provider: PROVIDER) ]
    seed_measurements_flow(wire, measurements, msr_rows: row)
    wrapper = RpcMErrorOnWellness.new(visit_gets_client, RPC_MEASUREMENTS)
    RpmsRpc.configure { |c| c.client = wrapper }

    err = assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    assert_match(/may have been filed/i, err.message)
    assert_equal 1, unlock_calls_for(RECORD_IEN).length
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
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
    SCREENING_EXTERNAL.fetch(key).fetch(code.to_s) { code.to_s }
  end

  def screening_wire(updates, internal: BASELINE_INTERNAL)
    merged = baseline_screening_pieces(internal)
    apply_screening_updates!(merged, updates)
    merged.join("|")
  end

  def baseline_screening_pieces(internal = BASELINE_INTERNAL)
    b = internal
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

  def pre_edit_body(ien, patient, internal:, signed: false, include_1112: true)
    patient_ien = internal.fetch(".08", patient)
    lines = [ "#{BH_VISIT_FILE}^#{ien}^.08^#{patient_ien}^PATIENT,SYNTH" ]
    if include_1112
      signed_at = signed ? "3251031.12" : ""
      lines << "#{BH_VISIT_FILE}^#{ien}^1112^#{signed_at}^SIGNED"
    end
    internal.each do |field, value|
      next if field == ".08"

      external = screening_result_external(field, value)
      lines << "#{BH_VISIT_FILE}^#{ien}^#{field}^#{value}^#{external}"
    end
    "[Data]\n#{lines.join("\n")}"
  end

  def screening_result_external(field, value)
    return value.to_s unless %w[1401 1403 1405 1407 1409].include?(field)

    external_for(field, value)
  end

  def visit_ddr_key(ien)
    ddr_key(file: BH_VISIT_FILE, iens: "#{ien},", fields: PRE_EDIT_FIELDS, flags: PRE_EDIT_FLAGS)
  end

  def visit_lock_node(rec)
    "^AMHREC(#{rec})"
  end

  def seed_visit_lock(rec, acquired: true)
    param = Ddr.lock_param(node: visit_lock_node(rec), timeout: 5).to_s
    @mock.seed_scalar(:ddr_lock_unlock_node, param, acquired)
  end

  def seed_visit_unlock(rec, success: true)
    param = Ddr.unlock_param(node: visit_lock_node(rec)).to_s
    @mock.seed_scalar(:ddr_lock_unlock_node, param, success)
  end

  def provider_ddr_key(ien)
    ddr_key(file: PROVIDER_FILE, iens: "#{ien},", fields: ".01", flags: "I")
  end

  def seed_provider_exists(ien, name: "PROVIDER,SYNTH")
    body = "[Data]\n#{PROVIDER_FILE}^#{ien}^.01^#{name}^#{name}"
    @mock.seed(:ddr_gets_entry_data, provider_ddr_key(ien), body)
  end

  def seed_provider_missing(ien)
    @mock.seed(:ddr_gets_entry_data, provider_ddr_key(ien), "[ERROR]")
  end

  def seed_provider_blank_dot01(ien)
    body = "[Data]\n#{PROVIDER_FILE}^#{ien}^.01^^"
    @mock.seed(:ddr_gets_entry_data, provider_ddr_key(ien), body)
  end

  def seed_provider_error_with_row(ien, name: "PROVIDER,SYNTH")
    body = "[Data]\n[ERROR]\n#{PROVIDER_FILE}^#{ien}^.01^#{name}^#{name}"
    @mock.seed(:ddr_gets_entry_data, provider_ddr_key(ien), body)
  end

  def provider_ddr_calls(ien)
    @mock.received_calls.select do |call|
      next false unless call[:rpc] == DDR_GETS

      param = call[:params].first
      param.is_a?(Hash) &&
        param["FILE"] == PROVIDER_FILE &&
        param["IENS"] == "#{ien}," &&
        param["FIELDS"] == ".01"
    end
  end

  def lock_calls_for(rec)
    node = visit_lock_node(rec)
    @mock.received_calls.select do |call|
      next false unless call[:rpc] == DDR_LOCK

      param = call[:params].first
      param.is_a?(Hash) && param["NODE"] == node && param["LOCKMODE"] == "1"
    end
  end

  def unlock_calls_for(rec)
    node = visit_lock_node(rec)
    @mock.received_calls.select do |call|
      next false unless call[:rpc] == DDR_LOCK

      param = call[:params].first
      param.is_a?(Hash) && param["NODE"] == node && !param.key?("LOCKMODE")
    end
  end

  def visit_gets_client
    @visit_gets_client || @mock
  end

  def install_visit_gets_sequence(ien, patient, pre_internal, post_internal, post_patient: patient,
                                  include_post_1112: true)
    key = visit_ddr_key(ien)
    pre_body = pre_edit_body(ien, patient, internal: pre_internal)
    post_body = pre_edit_body(
      ien, post_patient, internal: post_internal, include_1112: include_post_1112
    )
    @mock.seed(:ddr_gets_entry_data, key, pre_body)
    @visit_gets_client = VisitGetsReseedClient.new(@mock, key, [ post_body ])
    RpmsRpc.configure { |c| c.client = @visit_gets_client }
  end

  def seed_pre_edit_visit_gets(ien, patient, internal)
    seed_visit_lock(ien)
    key = visit_ddr_key(ien)
    @mock.seed(:ddr_gets_entry_data, key, pre_edit_body(ien, patient, internal: internal))
  end

  def seed_providers_for_screening_updates(updates)
    updates.each_value do |attrs|
      seed_provider_exists(attrs[:provider]) if attrs.key?(:provider)
    end
  end

  def seed_providers_for_measurements(measurements)
    measurements.each { |row| seed_provider_exists(row.fetch(:provider)) }
  end

  def seed_pre_edit_screening(ien, patient, error: false, signed: false, internal: BASELINE_INTERNAL)
    seed_visit_lock(ien)
    key = visit_ddr_key(ien)
    body = error ? "[ERROR]" : pre_edit_body(ien, patient, internal: internal, signed: signed)
    @mock.seed(:ddr_gets_entry_data, key, body)
  end

  def seed_post_edit_screening(ien, patient, internal)
    key = visit_ddr_key(ien)
    @mock.seed(:ddr_gets_entry_data, key, pre_edit_body(ien, patient, internal: internal))
  end

  def seed_screening_reply(wire, body)
    @mock.seed_text(:wellness_spec_save_screening, wire, body)
  end

  def seed_screening_success(wire, updates, post_overrides: nil)
    post = BASELINE_INTERNAL.merge(post_overrides || {})
    apply_screening_updates_to_internal!(post, updates)
    seed_screening_flow(wire, updates, post_internal: post)
  end

  def seed_screening_flow(wire, updates, post_internal:, reply: nil)
    seed_visit_lock(RECORD_IEN)
    seed_visit_unlock(RECORD_IEN)
    seed_providers_for_screening_updates(updates)
    seed_baseline_stored_screening_providers
    install_visit_gets_sequence(RECORD_IEN, PATIENT, BASELINE_INTERNAL, post_internal)
    seed_screening_reply(wire, reply || screening_success_body(RECORD_IEN))
  end

  def seed_baseline_stored_screening_providers
    seed_provider_exists(RESENT_PROVIDER)
    seed_provider_exists("413")
    seed_provider_exists("414")
    seed_provider_exists("415")
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

  def seed_measurements_success(wire, measurements, extra_msr_rows: [], record_ien: RECORD_IEN)
    rows = measurements.map do |m|
      msr_row(type_code: m.fetch(:type), value: m.fetch(:value), provider: m.fetch(:provider))
    end
    seed_measurements_flow(
      wire, measurements, msr_rows: rows + extra_msr_rows, record_ien: record_ien
    )
  end

  def seed_measurements_flow(wire, measurements, msr_rows: nil, msr_body: nil, reply: nil,
                             post_visit_internal: BASELINE_INTERNAL, post_patient: PATIENT,
                             record_ien: RECORD_IEN)
    seed_visit_lock(record_ien)
    seed_visit_unlock(record_ien)
    seed_providers_for_measurements(measurements)
    install_visit_gets_sequence(
      record_ien, PATIENT, BASELINE_INTERNAL, post_visit_internal, post_patient: post_patient
    )
    seed_measurements_reply(wire, reply || measurements_success_body(record_ien))
    if msr_body
      @mock.seed_text(:wellness_spec_visit_msr_entry, record_ien.to_s, msr_body)
    else
      seed_msr_read(record_ien, msr_rows || [])
    end
  end

  def seed_concurrent_measurements_success(wire, measurements, record_ien)
    rows = measurements.map do |m|
      msr_row(type_code: m.fetch(:type), value: m.fetch(:value), provider: m.fetch(:provider))
    end
    seed_visit_lock(record_ien)
    seed_visit_unlock(record_ien)
    key = visit_ddr_key(record_ien)
    body = pre_edit_body(record_ien, PATIENT, internal: BASELINE_INTERNAL)
    @mock.seed(:ddr_gets_entry_data, key, body)
    seed_providers_for_measurements(measurements)
    seed_measurements_reply(wire, measurements_success_body(record_ien))
    seed_msr_read(record_ien, rows)
  end

  def provider_ddr_param?(param)
    param.is_a?(Hash) &&
      param["FILE"] == PROVIDER_FILE &&
      param["FIELDS"] == ".01" &&
      param["FLAGS"] == "I"
  end

  def visit_ddr_param?(ien, param)
    param.is_a?(Hash) &&
      param["FILE"] == BH_VISIT_FILE &&
      param["IENS"] == "#{ien}," &&
      param["FIELDS"] == PRE_EDIT_FIELDS &&
      param["FLAGS"] == PRE_EDIT_FLAGS
  end

  def assert_non_gem_standard_error_during_save_raises_save_error(wrapper)
    measurements = [ { type: "PHQ9", value: 14, provider: PROVIDER } ]
    wire = "A|#{RECORD_IEN}|PHQ9~~14~#{PROVIDER}|#{PATIENT}"
    seed_measurements_success(wire, measurements)
    RpmsRpc.configure { |c| c.client = wrapper }

    err = assert_raises(save_error_class) do
      wellness.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements)
    end
    assert_match(/may have been filed/i, err.message)
    assert_equal 1, unlock_calls_for(RECORD_IEN).length
    if wrapper.respond_to?(:synthetic_error)
      refute_nil wrapper.synthetic_error,
                 "the synthetic broker failure must run, not a vacuous read-back mismatch"
    end
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end
end

class VisitGetsReseedClient < SimpleDelegator
  def initialize(delegate, visit_key, post_bodies)
    super(delegate)
    @visit_key = visit_key
    @post_bodies = post_bodies.dup
  end

  def call_rpc(rpc_name, *params)
    result = super
    if rpc_name == "DDR GETS ENTRY DATA" &&
       params.first.to_s == @visit_key && !@post_bodies.empty?
      __getobj__.seed(:ddr_gets_entry_data, @visit_key, @post_bodies.shift)
    end
    result
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

class UnlockRaiseClient < SimpleDelegator
  attr_reader :unlock_refusal_count

  def initialize(delegate, error_class, message)
    super(delegate)
    @error_class = error_class
    @message = message
    @unlock_refusal_count = 0
  end

  def call_rpc(rpc_name, *params)
    if rpc_name == "DDR LOCK/UNLOCK NODE" && unlock_param?(params.first)
      @unlock_refusal_count += 1
      raise @error_class, @message
    end

    super
  end

  def unlock_param?(param)
    param.is_a?(Hash) && param.key?("NODE") && !param.key?("LOCKMODE")
  end
end

class LockRpcTimeoutClient < SimpleDelegator
  def initialize(delegate, record_ien)
    super(delegate)
    @node = "^AMHREC(#{record_ien})"
  end

  def call_rpc(rpc_name, *params)
    param = params.first
    if rpc_name == "DDR LOCK/UNLOCK NODE" &&
       param.is_a?(Hash) && param["NODE"] == @node && param["LOCKMODE"] == "1"
      raise RpmsRpc::Client::RpcTimeoutError, "DDR LOCK timed out (synthetic)"
    end

    super
  end
end

class ReentrantWellnessSaveClient < SimpleDelegator
  attr_reader :inner_error, :measurements_rpc_before_reentry, :measurements_rpc_after_reentry,
              :rpc_count_before_reentry, :rpc_count_after_reentry

  def initialize(delegate, wellness_mod, record_ien:, patient:, trigger_rpc:, &inner_call)
    super(delegate)
    @wellness = wellness_mod
    @record_ien = record_ien
    @patient = patient
    @trigger_rpc = trigger_rpc
    @inner_call = inner_call
    @reentered = false
    @inner_error = nil
    @measurements_rpc_before_reentry = 0
    @measurements_rpc_after_reentry = 0
    @rpc_count_before_reentry = 0
    @rpc_count_after_reentry = 0
  end

  def call_rpc_global_array(rpc_name, *params)
    run_inner_once if !@reentered && rpc_name == @trigger_rpc
    super
  end

  def run_inner_once
    @reentered = true
    @rpc_count_before_reentry = received_calls.length
    @measurements_rpc_before_reentry = measurements_rpc_count
    begin
      @inner_call.call(@wellness)
    rescue StandardError => e
      @inner_error = e
    end
    @rpc_count_after_reentry = received_calls.length
    @measurements_rpc_after_reentry = measurements_rpc_count
  end

  def measurements_rpc_count
    received_calls.count { |c| c[:rpc] == "AMHG SAVE MEASUREMENTS" }
  end
end

class DualWrapperReentrantMeasurementsClient < SimpleDelegator
  attr_reader :inner_error, :rpc_count_before_reentry, :rpc_count_after_reentry

  def initialize(base, inner_wrapper, wellness_mod, record_ien:, patient:, &inner_call)
    super(base)
    @inner_wrapper = inner_wrapper
    @wellness = wellness_mod
    @record_ien = record_ien
    @patient = patient
    @inner_call = inner_call
    @reentered = false
    @inner_error = nil
    @rpc_count_before_reentry = 0
    @rpc_count_after_reentry = 0
  end

  def call_rpc_global_array(rpc_name, *params)
    run_inner_once if !@reentered && rpc_name == "AMHG SAVE MEASUREMENTS"
    super
  end

  def run_inner_once
    @reentered = true
    @rpc_count_before_reentry = received_calls.length
    begin
      RpmsRpc.with_client(@inner_wrapper) { @inner_call.call(@wellness) }
    rescue StandardError => e
      @inner_error = e
    end
    @rpc_count_after_reentry = received_calls.length
  end
end

class SwapClientOnLockAcquireClient < SimpleDelegator
  attr_reader :swapped

  def swapped?
    @swapped
  end

  def initialize(delegate, replacement_client, record_ien)
    super(delegate)
    @replacement_client = replacement_client
    @node = "^AMHREC(#{record_ien})"
    @swapped = false
  end

  def call_rpc(rpc_name, *params)
    param = params.first
    result = super
    if !@swapped && rpc_name == "DDR LOCK/UNLOCK NODE" && lock_acquire?(param)
      @swapped = true
      RpmsRpc.configure { |c| c.client = @replacement_client }
    end
    result
  end

  def lock_acquire?(param)
    param.is_a?(Hash) && param["NODE"] == @node && param["LOCKMODE"] == "1"
  end
end

class LockArgumentErrorAfterSendClient < SimpleDelegator
  def initialize(delegate, record_ien)
    super(delegate)
    @node = "^AMHREC(#{record_ien})"
  end

  def call_rpc(rpc_name, *params)
    param = params.first
    if rpc_name == "DDR LOCK/UNLOCK NODE" && lock_acquire?(param)
      super
      raise ArgumentError, "lock reply could not be parsed (synthetic)"
    end

    super
  end

  def lock_acquire?(param)
    param.is_a?(Hash) && param["NODE"] == @node && param["LOCKMODE"] == "1"
  end
end

class AfterWriteRpcErrorClient < SimpleDelegator
  MEASUREMENTS_RPC = "AMHG SAVE MEASUREMENTS"

  attr_reader :synthetic_error

  def initialize(delegate, rpc_name, error_class, message, require_write_first:)
    super(delegate)
    @rpc_name = rpc_name
    @error_class = error_class
    @message = message
    @require_write_first = require_write_first
    @write_sent = false
    @synthetic_error = nil
  end

  def call_rpc_global_array(rpc_name, *params)
    if rpc_name == MEASUREMENTS_RPC
      result = super
      @write_sent = true
      if @rpc_name == MEASUREMENTS_RPC
        @synthetic_error = @error_class.new(@message)
        raise @synthetic_error
      end
      return result
    end

    if rpc_name == @rpc_name && (!@require_write_first || @write_sent)
      result = super
      @synthetic_error = @error_class.new(@message)
      raise @synthetic_error
    end

    super
  end
end

class PostWriteVisitReadErrorClient < SimpleDelegator
  DDR_GETS = "DDR GETS ENTRY DATA"
  MEASUREMENTS_RPC = "AMHG SAVE MEASUREMENTS"

  attr_reader :synthetic_error

  def initialize(delegate, error_class, message)
    super(delegate)
    @error_class = error_class
    @message = message
    @write_sent = false
    @synthetic_error = nil
  end

  def call_rpc_global_array(rpc_name, *params)
    result = super
    @write_sent = true if rpc_name == MEASUREMENTS_RPC
    result
  end

  def call_rpc(rpc_name, *params)
    if @write_sent && rpc_name == DDR_GETS
      @synthetic_error = @error_class.new(@message)
      raise @synthetic_error
    end

    super
  end
end

class WellnessSessionClient < SimpleDelegator
  def initialize(delegate, session_id)
    super(delegate)
    @wellness_session_id = session_id
  end

  def session_id
    @wellness_session_id
  end
end

class NilSessionIdClient < SimpleDelegator
  def session_id
    nil
  end
end

class FalseSessionIdClient < SimpleDelegator
  def session_id
    false
  end
end

class SessionIdRaiseClient < SimpleDelegator
  def initialize(delegate, error_class, message)
    super(delegate)
    @error_class = error_class
    @message = message
  end

  def session_id
    raise @error_class, @message
  end
end

class SessionIdCallCountClient < SimpleDelegator
  attr_reader :session_id_calls

  def initialize(delegate, session_id)
    super(delegate)
    @wellness_session_id = session_id
    @session_id_calls = 0
  end

  def session_id
    @session_id_calls += 1
    @wellness_session_id
  end
end

class ForwardingWellnessClient
  def initialize(base)
    @base = base
  end

  def method_missing(name, *args, **kwargs, &block)
    @base.public_send(name, *args, **kwargs, &block)
  end

  def respond_to_missing?(name, include_private = false)
    @base.respond_to?(name, include_private) || super
  end
end

class CrossClientReentrantMeasurementsClient < SimpleDelegator
  attr_reader :inner_error, :rpc_count_before_reentry, :rpc_count_after_reentry

  def initialize(outer_client, inner_client, wellness_mod, record_ien:, patient:, measurements:)
    super(outer_client)
    @inner_client = inner_client
    @wellness = wellness_mod
    @record_ien = record_ien
    @patient = patient
    @measurements = measurements
    @reentered = false
    @inner_error = nil
    @rpc_count_before_reentry = 0
    @rpc_count_after_reentry = 0
  end

  def call_rpc_global_array(rpc_name, *params)
    run_inner_once if !@reentered && rpc_name == "AMHG SAVE MEASUREMENTS"
    super
  end

  def run_inner_once
    @reentered = true
    @rpc_count_before_reentry = received_calls.length
    begin
      RpmsRpc.with_client(@inner_client) do
        @wellness.save_measurements(@record_ien, patient: @patient, measurements: @measurements)
      end
    rescue StandardError => e
      @inner_error = e
    end
    @rpc_count_after_reentry = received_calls.length
  end
end

class InnerUnlockForbiddenClient < SimpleDelegator
  attr_reader :unlock_attempts

  def initialize(delegate)
    super
    @unlock_attempts = []
  end

  def call_rpc(rpc_name, *params)
    if rpc_name == "DDR LOCK/UNLOCK NODE" && unlock_param?(params.first)
      @unlock_attempts << params.first
    end

    super
  end

  def unlock_param?(param)
    param.is_a?(Hash) && param.key?("NODE") && !param.key?("LOCKMODE")
  end
end

class PostScreeningWriteUnlockRefuseClient < SimpleDelegator
  attr_reader :unlock_refusals

  def initialize(delegate)
    super
    @unlock_refusals = []
  end

  def call_rpc(rpc_name, *params)
    if rpc_name == "DDR LOCK/UNLOCK NODE" && unlock_param?(params.first)
      @unlock_refusals << params.first
      raise StandardError, "unlock refused on wrapper (synthetic)"
    end

    super
  end

  def unlock_param?(param)
    param.is_a?(Hash) && param.key?("NODE") && !param.key?("LOCKMODE")
  end
end

class DdrGetsIOErrorOnMatchClient < SimpleDelegator
  DDR_GETS = "DDR GETS ENTRY DATA"

  def initialize(delegate, match, message)
    super(delegate)
    @match = match
    @message = message
  end

  def call_rpc(rpc_name, *params)
    if rpc_name == DDR_GETS && @match.call(params.first)
      raise IOError, @message
    end

    super
  end
end

class BlockOnMeasurementsWriteClient < SimpleDelegator
  MEASUREMENTS_RPC = "AMHG SAVE MEASUREMENTS"

  # ContextScope on the inner mock holds @wire_lock for the whole scope,
  # including the release wait. Bind context here with a no-op wire lock so
  # another thread can finish a different-record save on the same client.
  def with_context(option_name, &block)
    synchronize_wire do
      inner = __getobj__
      next block.call if inner.current_context == option_name

      previous = inner.current_context
      inner.create_context(option_name)
      begin
        block.call
      ensure
        unless previous.nil? || previous == option_name
          begin
            inner.create_context(previous)
          rescue StandardError
            nil
          end
        end
      end
    end
  end

  def synchronize_wire(&block)
    block.call
  end

  def initialize(delegate, entered:, release:, record_ien:)
    super(delegate)
    @entered = entered
    @release = release
    @record_marker = "|#{record_ien}|"
  end

  def call_rpc_global_array(rpc_name, *params)
    wire = params.first.to_s
    if rpc_name == MEASUREMENTS_RPC && wire.include?(@record_marker)
      @entered.push(true)
      @release.pop(timeout: 5) || raise("timed out waiting for release (synthetic)")
    end
    super
  end
end
