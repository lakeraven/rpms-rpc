# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"

# Tests for referral detail and delete RPCs.
class ReferralLifecycleTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      m.seed(:referral_detail, "SR-001", { ien: "SR-001", status: "draft", patient_dfn: 1,
                                            type: "Cardiology", provider: "MARTINEZ,SARAH", facility: "ANMC" })
      m.seed(:referral_detail, "SR-002", { ien: "SR-002", status: "pending", patient_dfn: 1,
                                            type: "Orthopedics", provider: "CHEN,JAMES", facility: "ANMC" })
      m.seed(:referral_detail, "SR-003", { ien: "SR-003", status: "authorized", patient_dfn: 1,
                                            type: "Neurology", provider: "MARTINEZ,SARAH", facility: "ANMC" })
      m.seed(:referral_delete, "SR-001", { success: true, message: "Referral deleted" })
      m.seed(:referral_delete, "SR-002", { success: true, message: "Referral deleted" })
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # =============================================================================
  # REFERRAL DETAIL
  # =============================================================================

  def test_fetch_referral_detail_returns_data
    result = RpmsRpc::DataMapper.referral_detail.fetch_one("SR-001")

    refute_nil result
    assert_equal "SR-001", result[:ien]
    assert_equal "draft", result[:status]
    assert_equal "Cardiology", result[:type]
  end

  def test_fetch_referral_detail_different_statuses
    draft = RpmsRpc::DataMapper.referral_detail.fetch_one("SR-001")
    pending = RpmsRpc::DataMapper.referral_detail.fetch_one("SR-002")
    authorized = RpmsRpc::DataMapper.referral_detail.fetch_one("SR-003")

    assert_equal "draft", draft[:status]
    assert_equal "pending", pending[:status]
    assert_equal "authorized", authorized[:status]
  end

  def test_fetch_referral_detail_returns_nil_for_unknown
    assert_nil RpmsRpc::DataMapper.referral_detail.fetch_one("NONEXISTENT")
  end

  # =============================================================================
  # REFERRAL DELETE (scalar)
  # =============================================================================

  def test_fetch_referral_delete_returns_success
    result = RpmsRpc::DataMapper.referral_delete.fetch_one("SR-001")

    refute_nil result
    assert result[:success]
  end

  def test_fetch_referral_delete_returns_nil_for_unknown
    assert_nil RpmsRpc::DataMapper.referral_delete.fetch_one("NONEXISTENT")
  end

  def test_referral_detail_includes_type_and_provider
    result = RpmsRpc::DataMapper.referral_detail.fetch_one("SR-003")

    assert_equal "Neurology", result[:type]
    assert_equal "MARTINEZ,SARAH", result[:provider]
    assert_equal "ANMC", result[:facility]
  end
end
