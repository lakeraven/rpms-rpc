# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/immunization_refusal"

class ImmunizationRefusalTest < Minitest::Test
  DFN          = "8791"
  VACCINE_CODE = "207" # CVX for COVID-19 mRNA, LNP-S, PF

  def teardown
    RpmsRpc.reset!
  end

  def test_record_returns_success_with_saved_ien
    RpmsRpc.mock! do |m|
      m.seed_scalar(:immunization_refusal_save, DFN, "7001")
    end

    result = RpmsRpc::ImmunizationRefusal.record(DFN, VACCINE_CODE, reason_code: :parental)
    assert result[:success]
    assert_equal 7001, result[:ien]
  end

  def test_record_dispatches_with_dfn_and_payload
    RpmsRpc.mock! do |m|
      m.seed_scalar(:immunization_refusal_save, DFN, "7001")
    end

    RpmsRpc::ImmunizationRefusal.record(DFN, VACCINE_CODE, reason_code: :medical_contraindication, narrative: "anaphylaxis history")

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGOREP SET" }
    refute_nil call
    assert_equal DFN, call[:params][0]
    assert_includes call[:params][1], VACCINE_CODE
    assert_includes call[:params][1], "M"
    assert_includes call[:params][1], "anaphylaxis history"
  end

  def test_record_maps_each_reason_code_to_wire_code
    expected = { parental: "P", religious: "R", medical_contraindication: "M", patient_preference: "X", other: "O" }
    expected.each do |sym, code|
      RpmsRpc.mock! do |m|
        m.seed_scalar(:immunization_refusal_save, DFN, "7001")
      end
      RpmsRpc::ImmunizationRefusal.record(DFN, VACCINE_CODE, reason_code: sym)
      payload = RpmsRpc.client.received_calls.last[:params][1]
      parts = payload.split("^")
      assert_equal code, parts[1], "reason #{sym} should map to #{code}"
    end
  end

  def test_record_raises_on_unknown_reason_code
    assert_raises(ArgumentError) { RpmsRpc::ImmunizationRefusal.record(DFN, VACCINE_CODE, reason_code: :nope) }
  end

  def test_reason_code_is_required_keyword
    assert_raises(ArgumentError) { RpmsRpc::ImmunizationRefusal.record(DFN, VACCINE_CODE) }
  end

  def test_blank_args_return_failure
    refute RpmsRpc::ImmunizationRefusal.record(nil, VACCINE_CODE, reason_code: :parental)[:success]
    refute RpmsRpc::ImmunizationRefusal.record("0", VACCINE_CODE, reason_code: :parental)[:success]
    refute RpmsRpc::ImmunizationRefusal.record(DFN, "", reason_code: :parental)[:success]
  end
end
