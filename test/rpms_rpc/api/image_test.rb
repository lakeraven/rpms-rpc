# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/image"
require_relative "../captured_replies"

class ImageTest < Minitest::Test
  DFN = "8791"

  def teardown
    RpmsRpc.reset!
  end

  # Exam rows are proven against the build in test/live/image_exams_live_test.rb; these replay the
  # replies ORWRA IMAGING EXAMS1 sent for an exam filed on a throwaway container
  # (test/fixtures/captured_replies/orwra-imaging-exams1.yml, rpms-rpc#766).
  SLUG = "orwra-imaging-exams1"

  def replay(flow)
    client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(SLUG, flow))
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def test_an_exam_row_maps_in_the_order_get_orwra_writes_it
    replay("exams")

    rows = RpmsRpc::Image.exams_for_patient("990001")

    assert_equal 1, rows.size, "the BEG^END^MAX node is not an exam: #{rows.inspect}"
    row = rows.first
    assert_equal "DEMO IHS CLINIC;8904", row[:site]
    assert_equal "6738882.9664-1", row[:exam_id]
    assert_equal "3261117.0335", RpmsRpc::FilemanDateParser.format_datetime(row[:datetime])
    assert_equal "ABDOMEN 1 VIEW", row[:procedure]
    assert_equal "12345", row[:case_number]
    assert_equal "No Report", row[:status]
    assert_nil row[:abnormal]
  end

  def test_a_patient_with_no_exam_has_no_rows
    replay("no_exams")

    assert_empty RpmsRpc::Image.exams_for_patient("4")
  end

  def test_exams_blank_dfn_returns_empty
    assert_equal [], RpmsRpc::Image.exams_for_patient(nil)
    assert_equal [], RpmsRpc::Image.exams_for_patient("0")
  end
end
