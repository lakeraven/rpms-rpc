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

  # Exam rows are proven against the build in test/live/chart_tab_reads_live_test.rb.

  def test_exams_blank_dfn_returns_empty
    assert_equal [], RpmsRpc::Image.exams_for_patient(nil)
    assert_equal [], RpmsRpc::Image.exams_for_patient("0")
  end
end
