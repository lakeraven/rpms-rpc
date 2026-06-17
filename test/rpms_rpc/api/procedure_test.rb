# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/procedure"

class ProcedureTest < Minitest::Test
  DFN       = "8791"
  VISIT_IEN = "2090060"
  CPT       = "99213"

  def teardown
    RpmsRpc.reset!
  end

  def test_add_returns_success_with_saved_ien
    RpmsRpc.mock! do |m|
      m.seed_scalar(:procedure_save, DFN, "7001")
    end

    result = RpmsRpc::Procedure.add(DFN, VISIT_IEN, CPT)
    assert result[:success]
    assert_equal 7001, result[:ien]
  end

  def test_add_dispatches_bgovcpt_set_with_dfn_and_visit_ien
    RpmsRpc.mock! do |m|
      m.seed_scalar(:procedure_save, DFN, "7001")
    end

    RpmsRpc::Procedure.add(DFN, VISIT_IEN, CPT, modifiers: [ "25", "59" ], narrative: "office visit", quantity: 2)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGOVCPT SET" }
    refute_nil call
    assert_equal DFN, call[:params][0]
    assert_equal VISIT_IEN, call[:params][1]
    assert_includes call[:params][2], CPT
    assert_includes call[:params][2], "25,59"
    assert_includes call[:params][2], "office visit"
    assert_includes call[:params][2], "2"
  end

  def test_blank_args_return_failure
    refute RpmsRpc::Procedure.add(nil, VISIT_IEN, CPT)[:success]
    refute RpmsRpc::Procedure.add(DFN, nil, CPT)[:success]
    refute RpmsRpc::Procedure.add(DFN, VISIT_IEN, "")[:success]
  end

  def test_zero_save_response_yields_failure
    RpmsRpc.mock! do |m|
      m.seed_scalar(:procedure_save, DFN, "0")
    end
    refute RpmsRpc::Procedure.add(DFN, VISIT_IEN, CPT)[:success]
  end

  def test_nil_or_zero_quantity_returns_failure
    refute RpmsRpc::Procedure.add(DFN, VISIT_IEN, CPT, quantity: nil)[:success]
    refute RpmsRpc::Procedure.add(DFN, VISIT_IEN, CPT, quantity: 0)[:success]
    refute RpmsRpc::Procedure.add(DFN, VISIT_IEN, CPT, quantity: -1)[:success]
  end

  def test_for_patient_returns_empty_when_orwpce_unsupported
    RpmsRpc.mock!
    RpmsRpc.client.seed_capability(:orwpce_clinical_logs, supported: false)
    assert_equal [], RpmsRpc::Procedure.for_patient(DFN)
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWPCE PROCEDURE LIST" }
  end

  def test_for_patient_returns_empty_for_invalid_dfn_without_probing
    RpmsRpc.mock!
    [ nil, "", 0, -1, "abc" ].each do |bad|
      assert_equal [], RpmsRpc::Procedure.for_patient(bad)
    end
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWPCE PROCEDURE LIST" }
  end
end
