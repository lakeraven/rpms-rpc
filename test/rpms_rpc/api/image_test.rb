# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/image"

class ImageTest < Minitest::Test
  DFN = "8791"

  def teardown
    RpmsRpc.reset!
  end

  def test_exams_for_patient_returns_studies
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:image_exams, DFN, [
        { ien: 9001, exam_type: "CHEST X-RAY", status: "FINAL",   modality: "CR", description: "PA and lateral" },
        { ien: 9002, exam_type: "ECHO",        status: "PENDING", modality: "US", description: "Routine TTE" }
      ])
    end

    rows = RpmsRpc::Image.exams_for_patient(DFN)
    assert_equal 2, rows.length
    assert_equal "CHEST X-RAY", rows.first[:exam_type]
  end

  def test_exams_blank_dfn_returns_empty
    assert_equal [], RpmsRpc::Image.exams_for_patient(nil)
    assert_equal [], RpmsRpc::Image.exams_for_patient("0")
  end
end
