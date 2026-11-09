# frozen_string_literal: true

require "minitest/autorun"
require "delegate"
require "json"
require "rpms_rpc"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/behavioral_health/wellness"
require "rpms_rpc/retry_safety"
require_relative "../../captured_replies"

# AMHG SAVE SCREENING / AMHG SAVE MEASUREMENTS / AMHG GET VISIT MSR DATA ENTRY
# (rpms-rpc#540) through RpmsRpc::BehavioralHealth::Wellness.
#
# The guard and refusal cases, read from replies the pinned build sent
# (test/fixtures/captured_replies/amhg-wellness.yml): a screening save and
# then a measurement save on a BH visit for synthetic patient DFN 990045,
# captured in the gem's call order, and the refusals and errors the build
# sends (a lock another session holds, a visit and a provider not on file,
# AMHG's error reply). Replayed through CiaClient per ADR 0009. The round
# trips are proven by test/live/behavioral_health_wellness_live_test.rb
# (rpms-rpc#622, option b).
class BehavioralHealthWellnessTest < Minitest::Test
  W = RpmsRpc::BehavioralHealth::Wellness
  SLUG = "amhg-wellness"
  RPC_SCREENING = "AMHG SAVE SCREENING"
  RPC_MEASUREMENTS = "AMHG SAVE MEASUREMENTS"
  RPC_MSR_READ = "AMHG GET VISIT MSR DATA ENTRY"
  DDR_LOCK = "DDR LOCK/UNLOCK NODE"
  DDR_GETS = "DDR GETS ENTRY DATA"
  FILEMAN_CONTEXT = RpmsRpc::Patient::FILEMAN_CONTEXT
  WRITES = [ RPC_SCREENING, RPC_MEASUREMENTS ].freeze

  ROOT = File.expand_path("../../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  def self.capture(name) = CapturedReplies.file(SLUG).fetch("captures").find { |c| c["name"] == name }

  SCREENING_WIRE = capture("save_screening").fetch("inputs").first
  MEASUREMENTS_WIRE = capture("save_measurements").fetch("inputs").first
  RECORD_IEN, PATIENT = MEASUREMENTS_WIRE.split("|", -1).values_at(1, 3)
  PROVIDER = "4"
  OTHER_PATIENT = "990037"
  NOT_ON_FILE = "999999"
  COMMENT = "Synthetic alcohol screening note"
  ALCOHOL = { alcohol: { result: "N", provider: PROVIDER, comment: COMMENT } }.freeze
  PHQ9 = [ { type: "PHQ9", value: 14, provider: PROVIDER } ].freeze

  # A replay client that also notes the option each RPC ran under.
  class ContextReplay < CapturedReplies::ReplayCiaClient
    def call_rpc_raw(rpc_name, *params)
      super.tap { @calls.last[:context] = current_context }
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def raw(name) = CapturedReplies.raw(SLUG, name)

  def use(script)
    @client = ContextReplay.new(script.transform_values { |names| names.map { |n| raw(n) } })
    RpmsRpc.configure { |cfg| cfg.client = @client }
    @client
  end

  # The captured screening save; any capture can stand in for one step.
  def replay_screening(lock: "lock", visit: "visit_before", provider: "provider", save: "save_screening")
    use(DDR_LOCK => [ lock, "unlock" ],
        DDR_GETS => [ visit, provider, "visit_after_screening" ],
        RPC_SCREENING => [ save ])
  end

  # The captured measurement save, made after the screening save.
  def replay_measurements(lock: "lock", visit: "visit_after_screening")
    use(DDR_LOCK => [ lock, "unlock" ],
        DDR_GETS => [ visit, "provider", "visit_after_measurements" ],
        RPC_MEASUREMENTS => [ "save_measurements" ],
        RPC_MSR_READ => [ "msr_read" ])
  end

  def rpcs = @client.calls.map { |c| c[:rpc] }.grep(String)
  def write_calls = @client.calls.select { |c| WRITES.include?(c[:rpc]) }
  def unlock_calls = @client.calls.select { |c| c[:rpc] == DDR_LOCK && !c[:params].first.key?("LOCKMODE") }

  def assert_refused_before_write(pattern = nil)
    err = assert_raises(W::SaveError) { yield }
    assert_match pattern, err.message if pattern
    assert_empty write_calls, "nothing may reach an AMHG write"
    err
  end

  # --- the captured saves -----------------------------------------------------

  def test_the_captured_screening_save_returns_what_the_visit_read_back
    replay_screening

    result = W.save_screening(RECORD_IEN, patient: PATIENT, screenings: ALCOHOL)

    assert_equal RECORD_IEN, result[:record_ien]
    assert_equal({ result: "N", provider: PROVIDER, comment: COMMENT }, result[:screenings][:alcohol])
    assert_equal({ result: "", provider: "", comment: "" }, result[:screenings][:depression])
  end

  def test_the_screening_save_sends_the_nineteen_piece_wire_the_build_filed
    replay_screening
    W.save_screening(RECORD_IEN, patient: PATIENT, screenings: ALCOHOL)

    assert_equal [ SCREENING_WIRE ], write_calls.first[:params]
    assert_equal 19, SCREENING_WIRE.split("|", -1).length
  end

  def test_the_screening_save_locks_reads_writes_reads_back_and_unlocks_in_order
    replay_screening
    W.save_screening(RECORD_IEN, patient: PATIENT, screenings: ALCOHOL)

    assert_equal [ DDR_LOCK, DDR_GETS, DDR_GETS, RPC_SCREENING, DDR_GETS, DDR_LOCK ], rpcs
  end

  # Every request is the one the build answered: the lock and unlock NODE, the
  # visit IENS, the provider read, the writes and the MSR read.
  def test_each_request_is_the_one_the_capture_answered
    inputs = ->(names) { names.map { |n| self.class.capture(n).fetch("inputs") } }
    sent = -> { @client.calls.select { |c| c[:rpc].is_a?(String) }.map { |c| c[:params] } }

    replay_screening
    W.save_screening(RECORD_IEN, patient: PATIENT, screenings: ALCOHOL)
    assert_equal inputs.(%w[lock visit_before provider save_screening visit_after_screening unlock]), sent.()

    replay_measurements
    W.save_measurements(RECORD_IEN, patient: PATIENT, measurements: PHQ9)
    assert_equal inputs.(%w[lock visit_after_screening provider save_measurements visit_after_measurements msr_read unlock]),
                 sent.()
  end

  def test_the_write_runs_under_amhgrpc_and_the_fileman_calls_under_the_fileman_context
    replay_screening
    caller_context = @client.current_context
    W.save_screening(RECORD_IEN, patient: PATIENT, screenings: ALCOHOL)

    assert_equal "AMHGRPC", write_calls.first[:context]
    @client.calls.select { |c| [ DDR_LOCK, DDR_GETS ].include?(c[:rpc]) }.each do |call|
      assert_equal FILEMAN_CONTEXT, call[:context], "#{call[:rpc]} must run under the FileMan context"
    end
    assert_equal caller_context, @client.current_context
  end

  def test_the_captured_measurement_save_returns_the_msr_read_back
    replay_measurements

    rows = W.save_measurements(RECORD_IEN, patient: PATIENT, measurements: PHQ9)

    phq = rows.find { |r| r[:type] == "PHQ9" }
    assert_equal 14, phq[:value]
    assert_equal PROVIDER, phq.dig(:provider, :ien)
    assert_equal [ MEASUREMENTS_WIRE ], write_calls.first[:params]
    assert_equal [ DDR_LOCK, DDR_GETS, DDR_GETS, RPC_MEASUREMENTS, DDR_GETS, RPC_MSR_READ, DDR_LOCK ], rpcs
  end

  # --- refusals the build sends -----------------------------------------------

  def test_a_lock_another_session_holds_is_refused_before_any_read_and_released
    [ -> { W.save_screening(RECORD_IEN, patient: PATIENT, screenings: ALCOHOL) },
      -> { W.save_measurements(RECORD_IEN, patient: PATIENT, measurements: PHQ9) } ].each do |save|
      replay_screening(lock: "lock_held_elsewhere")

      err = assert_refused_before_write(/was not acquired/i) { save.call }

      refute_match(/may have been filed/i, err.message)
      refute_includes rpcs, DDR_GETS
      assert_equal 1, unlock_calls.length, "a sent, unacquired lock is released"
    end
  end

  def test_a_visit_not_on_file_is_refused_before_the_write
    replay_screening(visit: "visit_not_on_file")

    assert_refused_before_write { W.save_screening(NOT_ON_FILE, patient: PATIENT, screenings: ALCOHOL) }
    assert_equal 1, unlock_calls.length
  end

  def test_a_provider_not_on_file_200_is_refused_before_the_write
    replay_screening(provider: "provider_not_on_file")
    screenings = { alcohol: { result: "N", provider: NOT_ON_FILE, comment: COMMENT } }

    assert_refused_before_write { W.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings) }
    assert_equal 1, unlock_calls.length
  end

  # The visit names DFN 990045; a save for another patient is refused.
  def test_a_visit_of_another_patient_is_refused_before_the_write
    replay_screening
    assert_refused_before_write { W.save_screening(RECORD_IEN, patient: OTHER_PATIENT, screenings: ALCOHOL) }

    replay_measurements
    assert_refused_before_write { W.save_measurements(RECORD_IEN, patient: OTHER_PATIENT, measurements: PHQ9) }
  end

  # AMHG answers 0~Edit Screening when it files nothing (the build's reply for
  # a visit not on file).
  def test_amhg_error_reply_is_an_outcome_unknown_save_error_and_unlocks
    replay_screening(save: "save_screening_not_on_file")

    err = assert_raises(W::SaveError) { W.save_screening(RECORD_IEN, patient: PATIENT, screenings: ALCOHOL) }

    refute_empty write_calls
    assert_match(/outcome unknown/i, err.message)
    assert_match(/may have been filed/i, err.message)
    refute_includes err.message, "Edit Screening"
    assert_equal 1, unlock_calls.length
  end

  # The MSR read-back holds PHQ9 14; a save that sent 15 is not confirmed by it.
  def test_a_measurement_readback_that_does_not_match_is_not_confirmed
    replay_measurements

    err = assert_raises(W::SaveError) do
      W.save_measurements(RECORD_IEN, patient: PATIENT, measurements: [ PHQ9.first.merge(value: 15) ])
    end

    assert_match(/outcome unknown/i, err.message)
    assert_equal 1, unlock_calls.length
  end

  # The screening read-back holds the comment the build filed; a save that sent
  # another comment is not confirmed by it.
  def test_a_screening_readback_that_does_not_match_is_not_confirmed
    replay_screening
    other = { alcohol: { result: "N", provider: PROVIDER, comment: "Another synthetic note" } }

    err = assert_raises(W::SaveError) { W.save_screening(RECORD_IEN, patient: PATIENT, screenings: other) }

    assert_match(/outcome unknown/i, err.message)
    refute_includes err.message, "Another synthetic note"
  end

  # A save already in progress for this record on this client is refused.
  class ReenterOnWrite < SimpleDelegator
    attr_reader :inner_error, :calls_before, :calls_after

    def initialize(client, &inner)
      super(client)
      @inner = inner
    end

    def call_rpc_global_array(rpc_name, *params)
      if WRITES.include?(rpc_name) && !@reentered
        @reentered = true
        @calls_before = calls.length
        begin
          @inner.call
        rescue StandardError => e
          @inner_error = e
        end
        @calls_after = calls.length
      end
      super
    end
  end

  def test_a_reentrant_save_on_the_same_client_and_record_is_refused_before_any_rpc
    replay_screening
    wrapper = ReenterOnWrite.new(@client) { W.save_measurements(RECORD_IEN, patient: PATIENT, measurements: PHQ9) }
    RpmsRpc.configure { |cfg| cfg.client = wrapper }

    W.save_screening(RECORD_IEN, patient: PATIENT, screenings: ALCOHOL)

    assert_instance_of W::SaveError, wrapper.inner_error
    assert_match(/in progress/i, wrapper.inner_error.message)
    assert_equal wrapper.calls_before, wrapper.calls_after, "a refused nested save sends no RPC"
  end

  # --- argument guards: refused before any write -------------------------------

  def test_screening_arguments_are_refused_before_any_write
    {
      {} => /screening/i,
      { bogus: { result: "N" } } => /screening/i,
      { depression: { result: "ZZ" } } => /screening result is not a filed code/i,
      { depression: { result: "P", provider: "0", comment: "Ok note here" } } => /provider must be a positive integer/i,
      { depression: { result: "P", provider: PROVIDER, comment: "x" } } => /2 to 245 characters/i,
      { depression: { result: "P", provider: PROVIDER, comment: "x" * 246 } } => /2 to 245 characters/i,
      { depression: { result: "P", provider: PROVIDER, comment: "Ā" * 123 } } => /2 to 245 characters/i
    }.each do |screenings, pattern|
      replay_screening
      assert_refused_before_write(pattern) { W.save_screening(RECORD_IEN, patient: PATIENT, screenings: screenings) }
    end
  end

  def test_a_separator_or_control_in_a_comment_is_refused_without_echoing_it
    [ "|", "^", "\n", "\x1e" ].each do |bad|
      replay_screening
      comment = "ab#{bad}cd"
      err = assert_refused_before_write(/separator or control character/i) do
        W.save_screening(RECORD_IEN, patient: PATIENT,
                                     screenings: { depression: { result: "P", provider: PROVIDER, comment: comment } })
      end
      refute_includes err.message, comment
    end
  end

  def test_record_ien_and_patient_must_be_positive_integers
    [
      [ -> { W.save_screening("0", patient: PATIENT, screenings: ALCOHOL) }, /record IEN must be a positive integer/i ],
      [ -> { W.save_screening("-1", patient: PATIENT, screenings: ALCOHOL) }, /record IEN must be a positive integer/i ],
      [ -> { W.save_screening(RECORD_IEN, patient: "0", screenings: ALCOHOL) }, /patient must be a positive integer/i ],
      [ -> { W.save_measurements(RECORD_IEN, record_ien: RECORD_IEN, patient: PATIENT, measurements: PHQ9) },
        /record IEN must be a positive integer/i ],
      [ -> { W.save_measurements(RECORD_IEN, patient: PATIENT, measurements: PHQ9, note: "x") }, /field is not accepted/i ]
    ].each do |save, pattern|
      replay_measurements
      assert_refused_before_write(pattern) { save.call }
    end
  end

  def test_measurement_arguments_are_refused_before_any_write
    base = PHQ9.first
    cases = [
      [ [], /measurements are required/i ],
      [ [ base.merge(type: "BOGUS") ], /measurement type is not a filed code/i ],
      [ [ base, base ], /measurement type is duplicated/i ],
      [ [ base.merge(value: 28) ], /not an integer in range/i ],
      [ [ base.merge(value: -1) ], /not an integer in range/i ],
      [ [ base.merge(value: "14.5") ], /not an integer in range/i ],
      [ [ base.merge(value: "1e1") ], /not an integer in range/i ],
      [ [ base.merge(type: "GAD7", value: 22) ], /not an integer in range/i ],
      [ [ base.merge(provider: nil) ], /provider must be a positive integer/i ]
    ]
    cases.each do |measurements, pattern|
      replay_measurements
      assert_refused_before_write(pattern) { W.save_measurements(RECORD_IEN, patient: PATIENT, measurements: measurements) }
    end
  end

  # --- registry ---------------------------------------------------------------

  def test_required_rpcs_lists_wellness_write_and_read_rpcs
    rpcs = JSON.parse(File.read(REQUIRED_RPCS_PATH)).fetch("modules").fetch("RpmsRpc::BehavioralHealth::Wellness")

    assert_includes rpcs, RPC_SCREENING
    assert_includes rpcs, RPC_MEASUREMENTS
    assert_includes rpcs, RPC_MSR_READ
  end

  def test_retry_safety_classifies_both_writes_as_non_idempotent
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(W, :save_screening)
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(W, :save_measurements)
  end

  def test_save_error_is_a_behavioral_health_save_error_and_an_rpms_rpc_error
    assert_operator W::SaveError, :<, RpmsRpc::BehavioralHealth::SaveError
    assert_operator W::SaveError, :<, RpmsRpc::Error
  end
end
