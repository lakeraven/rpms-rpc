# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/image"

class ImageTest < Minitest::Test
  DFN       = "8791"
  STUDY_IEN = "9001"

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

  def test_launch_token_returns_token_with_default_ttl
    RpmsRpc.mock! do |m|
      m.seed_scalar(:image_launch_token, DFN, "tok-abc-123")
    end

    before = Time.now
    result = RpmsRpc::Image.launch_token(DFN, STUDY_IEN)
    after = Time.now

    assert_equal "tok-abc-123", result[:token]
    assert_nil result[:viewer_url], "viewer_url is filled by integration layer, not the gateway"
    assert result[:expires_at] >= before + RpmsRpc::Image::DEFAULT_TTL_SECONDS - 1
    assert result[:expires_at] <= after + RpmsRpc::Image::DEFAULT_TTL_SECONDS + 1
  end

  def test_launch_token_honors_ttl_seconds_kw
    RpmsRpc.mock! do |m|
      m.seed_scalar(:image_launch_token, DFN, "tok-xyz")
    end

    before = Time.now
    result = RpmsRpc::Image.launch_token(DFN, STUDY_IEN, ttl_seconds: 60)
    after = Time.now

    assert result[:expires_at] >= before + 60 - 1, "expires_at must be at least before+ttl"
    assert result[:expires_at] <= after + 60 + 1, "expires_at must be at most after+ttl"
  end

  def test_launch_token_rejects_nil_zero_negative_or_non_numeric_ttl
    RpmsRpc.mock! do |m|
      m.seed_scalar(:image_launch_token, DFN, "tok-abc")
    end

    assert_nil RpmsRpc::Image.launch_token(DFN, STUDY_IEN, ttl_seconds: nil)
    assert_nil RpmsRpc::Image.launch_token(DFN, STUDY_IEN, ttl_seconds: 0)
    assert_nil RpmsRpc::Image.launch_token(DFN, STUDY_IEN, ttl_seconds: -10)
    assert_nil RpmsRpc::Image.launch_token(DFN, STUDY_IEN, ttl_seconds: "not a number")
  end

  def test_launch_token_dispatches_magg_with_dfn_and_study_ien
    RpmsRpc.mock! do |m|
      m.seed_scalar(:image_launch_token, DFN, "tok-abc")
    end

    RpmsRpc::Image.launch_token(DFN, STUDY_IEN)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "MAGG IMAGE LAUNCH TOKEN" }
    refute_nil call
    assert_equal [ DFN, STUDY_IEN ], call[:params]
  end

  def test_launch_token_blank_args_return_nil
    assert_nil RpmsRpc::Image.launch_token(nil, STUDY_IEN)
    assert_nil RpmsRpc::Image.launch_token(DFN, "0")
  end

  def test_launch_token_blank_response_returns_nil
    RpmsRpc.mock! do |m|
      m.seed_scalar(:image_launch_token, DFN, "")
    end
    assert_nil RpmsRpc::Image.launch_token(DFN, STUDY_IEN)
  end
end
