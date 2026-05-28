# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/pov"

class PovTest < Minitest::Test
  DFN       = "8791"
  VISIT_IEN = "2090059"
  ICD       = "I10"

  def teardown
    RpmsRpc.reset!
  end

  def test_add_returns_success_with_saved_ien
    RpmsRpc.mock! do |m|
      m.seed_scalar(:visit_data_save, DFN, "9001")
    end

    result = RpmsRpc::Pov.add(DFN, VISIT_IEN, ICD)
    assert result[:success]
    assert_equal 9001, result[:ien]
  end

  def test_add_dispatches_bgovupd_set_with_pov_record_type
    RpmsRpc.mock! do |m|
      m.seed_scalar(:visit_data_save, DFN, "9001")
    end

    RpmsRpc::Pov.add(DFN, VISIT_IEN, ICD, narrative: "Essential hypertension")

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGOVUPD SET" }
    refute_nil call
    assert_equal DFN, call[:params][0]
    assert_equal VISIT_IEN, call[:params][1]
    assert_match(/\APOV\^/, call[:params][2])
    assert_includes call[:params][2], ICD
    assert_includes call[:params][2], "Essential hypertension"
  end

  def test_add_with_primary_modifier_marks_payload
    RpmsRpc.mock! do |m|
      m.seed_scalar(:visit_data_save, DFN, "9001")
    end

    RpmsRpc::Pov.add(DFN, VISIT_IEN, ICD, modifiers: { primary: true })

    payload = RpmsRpc.client.received_calls.last[:params][2]
    assert_includes payload, "P"
  end

  def test_add_with_injury_cause_modifier
    RpmsRpc.mock! do |m|
      m.seed_scalar(:visit_data_save, DFN, "9001")
    end

    RpmsRpc::Pov.add(DFN, VISIT_IEN, ICD, modifiers: { injury_cause: "FALL" })

    payload = RpmsRpc.client.received_calls.last[:params][2]
    assert_includes payload, "FALL"
  end

  def test_blank_args_return_failure
    refute RpmsRpc::Pov.add(nil, VISIT_IEN, ICD)[:success]
    refute RpmsRpc::Pov.add(DFN, nil, ICD)[:success]
    refute RpmsRpc::Pov.add(DFN, VISIT_IEN, "")[:success]
  end
end
