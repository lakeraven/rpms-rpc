# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/allergy"
require "rpms_rpc/retry_safety"

# ORWDAL32 SAVE ALLERGY — EDITSAVE^ORWDAL32 (ORWDAL32.m:119-128) ->
# UPDATE^GMRAGUI1 / NKA^GMRAGUI1 (GMRAGUI1.m:68-84, :86-148).
class AllergySaveTest < Minitest::Test
  DFN = "8791"
  RPC = "ORWDAL32 SAVE ALLERGY"

  # MESS^GMRAGUI1 (GMRAGUI1.m:151-157)
  LOCK_REPLY = "-1^Another user is editing this patient's allergy information.  " \
               "Please refresh/review the patient's information before proceeding."

  SYNTH_ALLERGY = {
    agent: "PENICILLIN",
    agent_pointer: "125;PSNDF(50.6,",
    type: "D",
    nature: "A",
    originator: "42",
    originated_at: "3261015.1045",
    observed_or_historical: "o",
    symptoms: [ { ien: "10", text: "RASH", date: "3261015" } ],
    comments: [ "synthetic comment" ],
    reaction_date: "3261015",
    severity: "MODERATE"
  }.freeze

  REQUIRED_RPCS_PATH = File.expand_path("../../../lib/rpms_rpc/required_rpcs.json", __dir__)

  def teardown
    RpmsRpc.reset!
  end

  # --- wiring (EDITSAVE^ORWDAL32: ORALIEN, ORDFN, OREDITED list) ------------

  def test_save_dispatches_orwdal32_save_allergy_with_formal_order_and_list_shape
    seed_save_reply("0")
    RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)

    call = save_call
    refute_nil call, "expected #{RPC}"
    # ORY is broker return; client params are ORALIEN, ORDFN, OREDITED (ORWDAL32.m:119).
    assert_equal [ "", DFN, expected_edited(SYNTH_ALLERGY) ], call[:params]
  end

  def test_save_success_without_progress_note
    seed_save_reply("0")
    result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
    assert result[:success]
    assert_nil result[:note_ien]
  end

  def test_save_success_with_progress_note_ien
    seed_save_reply("0^4242")
    result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
    assert result[:success]
    assert_equal 4242, result[:note_ien]
  end

  def test_save_maps_duplicate_failure
    agent = SYNTH_ALLERGY[:agent]
    seed_save_reply("-1^Patient already has a #{agent} reaction entered.  No duplicates allowed.")
    result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
    refute result[:success]
    assert_equal :duplicate, result[:error]
    assert_equal "-1^Patient already has a #{agent} reaction entered.  No duplicates allowed.",
                 result[:message]
  end

  def test_save_maps_lock_failure
    seed_save_reply(LOCK_REPLY)
    result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
    refute result[:success]
    assert_equal :locked, result[:error]
    assert_equal LOCK_REPLY, result[:message]
  end

  def test_save_maps_unknown_minus_one_as_rejected
    seed_save_reply("-1^synthetic broker rejection")
    result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
    refute result[:success]
    assert_equal :rejected, result[:error]
    assert_equal "-1^synthetic broker rejection", result[:message]
  end

  def test_save_empty_replies_fail_closed
    [ "", [], nil ].each do |reply|
      RpmsRpc.reset!
      with_broker_reply(reply) do
        result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
        refute result[:success], "reply #{reply.inspect} must not succeed"
        assert_equal :empty_reply, result[:error]
      end
    end
  end

  def test_save_malformed_replies_fail_closed
    %w[1 0^abc OK].each do |reply|
      RpmsRpc.reset!
      seed_save_reply(reply)
      result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
      refute result[:success], "reply #{reply.inspect} must not succeed"
      assert_equal :malformed_reply, result[:error]
    end
  end

  def test_save_rejects_invalid_dfn_without_rpc
    [ nil, "", "0", "abc", "12abc" ].each do |dfn|
      RpmsRpc.mock!
      result = RpmsRpc::Allergy.save(dfn, SYNTH_ALLERGY)
      refute result[:success]
      assert_empty RpmsRpc.client.received_calls
    end
  end

  def test_save_rejects_missing_required_fields_without_rpc
    %i[agent agent_pointer type nature originator originated_at observed_or_historical].each do |field|
      RpmsRpc.mock!
      attrs = SYNTH_ALLERGY.dup
      attrs.delete(field)
      result = RpmsRpc::Allergy.save(DFN, attrs)
      refute result[:success]
      assert_empty RpmsRpc.client.received_calls
    end
  end

  # --- no known allergies (GMRANKA^GMRAGUI1 NKA path) -----------------------

  def test_no_known_allergies_dispatches_nka_list_param
    seed_save_reply("0")
    RpmsRpc::Allergy.no_known_allergies(DFN)

    call = save_call
    assert_equal [ "", DFN, { "GMRANKA" => "YES" } ], call[:params]
  end

  def test_no_known_allergies_success_on_zero
    seed_save_reply("0")
    result = RpmsRpc::Allergy.no_known_allergies(DFN)
    assert result[:success]
    assert_nil result[:note_ien] if result.key?(:note_ien)
  end

  def test_no_known_allergies_maps_active_allergies_failure
    seed_save_reply("-1^Patient has active allergies - can't mark as NKA")
    result = RpmsRpc::Allergy.no_known_allergies(DFN)
    refute result[:success]
    assert_equal :active_allergies, result[:error]
  end

  def test_no_known_allergies_maps_assessment_update_failure
    seed_save_reply("-1^Unable to update assessment - try again.")
    result = RpmsRpc::Allergy.no_known_allergies(DFN)
    refute result[:success]
    assert_equal :assessment_update_failed, result[:error]
  end

  def test_no_known_allergies_maps_lock_failure
    seed_save_reply(LOCK_REPLY)
    result = RpmsRpc::Allergy.no_known_allergies(DFN)
    refute result[:success]
    assert_equal :locked, result[:error]
  end

  def test_no_known_allergies_rejects_invalid_dfn_without_rpc
    RpmsRpc.mock!
    refute RpmsRpc::Allergy.no_known_allergies(nil)[:success]
    assert_empty RpmsRpc.client.received_calls
  end

  # --- safety / compatibility ------------------------------------------------

  def test_neither_write_path_uses_ddr_filer
    seed_save_reply("0")
    RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
    RpmsRpc::Allergy.no_known_allergies(DFN)
    refute RpmsRpc.client.received_calls.any? { |c| c[:rpc] == "DDR FILER" }
  end

  def test_retry_safety_classifies_both_writes_as_non_idempotent
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(RpmsRpc::Allergy, :save)
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(RpmsRpc::Allergy, :no_known_allergies)
  end

  def test_required_rpcs_lists_save_allergy_under_allergy_module
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    assert_includes doc.fetch("modules").fetch("RpmsRpc::Allergy"), RPC
  end

  private

  def save_call
    RpmsRpc.client.received_calls.find { |c| c[:rpc] == RPC }
  end

  # Two-level GMRASYMP / GMRACMTS subscripts (GMRAGUI1.m:116-118) use the
  # transport's array-key encoding (CiaClient#m_subscript / XwbClient#m_subscript).
  def expected_edited(allergy)
    edited = {
      "GMRAGNT" => "#{allergy[:agent]}^#{allergy[:agent_pointer]}",
      "GMRATYPE" => allergy[:type],
      "GMRANATR" => allergy[:nature],
      "GMRAORIG" => allergy[:originator].to_s,
      "GMRAORDT" => allergy[:originated_at],
      "GMRAOBHX" => allergy[:observed_or_historical]
    }
    allergy[:symptoms]&.each_with_index do |sym, idx|
      edited[[ "GMRASYMP", idx + 1 ]] = "#{sym[:ien]}^#{sym[:text]}^#{sym[:date]}"
    end
    allergy[:comments]&.each_with_index do |line, idx|
      edited[[ "GMRACMTS", idx + 1 ]] = line
    end
    edited["GMRARDT"] = allergy[:reaction_date] if allergy[:reaction_date]
    edited["GMRASEVR"] = allergy[:severity] if allergy[:severity]
    edited
  end

  def seed_save_reply(value)
    RpmsRpc.mock!
    scalars = RpmsRpc.client.instance_variable_get(:@scalars)
    scalars[RPC] = { "" => value }
  end

  def with_broker_reply(reply)
    client = RpmsRpc::MockClient.new
    client.define_singleton_method(:call_rpc) do |rpc_name, *params|
      received_calls << { rpc: rpc_name, params: params, context: current_context }
      return reply if rpc_name == RPC

      ""
    end
    RpmsRpc.configure { |cfg| cfg.client = client }
    yield
  end
end
