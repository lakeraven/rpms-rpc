# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/exam_component"

class ExamComponentTest < Minitest::Test
  DFN       = "8791"
  VISIT_IEN = "2090059"
  EXAM_CODE = "SK"

  def teardown
    RpmsRpc.reset!
  end

  def test_add_returns_success_with_saved_ien
    RpmsRpc.mock! do |m|
      m.seed_scalar(:visit_data_save, DFN, "6001")
    end

    result = RpmsRpc::ExamComponent.add(DFN, VISIT_IEN, EXAM_CODE, finding: "NORMAL")
    assert result[:success]
    assert_equal 6001, result[:ien]
  end

  def test_add_dispatches_bgovupd_set_with_exam_record_type
    RpmsRpc.mock! do |m|
      m.seed_scalar(:visit_data_save, DFN, "6001")
    end

    RpmsRpc::ExamComponent.add(DFN, VISIT_IEN, EXAM_CODE, finding: "ABNORMAL", narrative: "see note")

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGOVUPD SET" }
    refute_nil call
    assert_match(/\AEXAM\^/, call[:params][2])
    assert_includes call[:params][2], EXAM_CODE
    assert_includes call[:params][2], "ABNORMAL"
  end

  def test_blank_finding_required
    refute RpmsRpc::ExamComponent.add(DFN, VISIT_IEN, EXAM_CODE, finding: "")[:success]
    refute RpmsRpc::ExamComponent.add(DFN, VISIT_IEN, EXAM_CODE, finding: nil)[:success]
  end

  def test_blank_args_return_failure
    refute RpmsRpc::ExamComponent.add(nil, VISIT_IEN, EXAM_CODE, finding: "X")[:success]
    refute RpmsRpc::ExamComponent.add(DFN, "0", EXAM_CODE, finding: "X")[:success]
    refute RpmsRpc::ExamComponent.add(DFN, VISIT_IEN, "", finding: "X")[:success]
  end
end
