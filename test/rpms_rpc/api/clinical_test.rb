# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/practitioner"
require "rpms_rpc/api/referral"

# Tests for clinical data symbolic APIs.
class ClinicalTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      # ORWU USERINFO returns the authenticated session user only; mock
      # under empty key to match the dispatch (fetch_one with no params).
      m.seed(:practitioner_info, "", {
        duz: 101, name: "MARTINEZ,SARAH", user_class: 3,
        kernel_domain: "DEMO.IHS.GOV", site_ien: 8904
      })
      m.seed_collection(:practitioner_list,
        [ { ien: 101, name: "MARTINEZ,SARAH", title: "MD" } ],
        filter_field: :name)
      m.seed(:referral_detail, "SR-001", { ien: "SR-001", status: "draft", patient_dfn: 1, type: "Cardiology" })
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # =============================================================================
  # PRACTITIONER
  # =============================================================================

  def test_practitioner_find_returns_session_user_when_ien_matches
    result = RpmsRpc::Practitioner.find(101)

    refute_nil result
    assert_equal "MARTINEZ,SARAH", result[:name]
    assert_equal 101, result[:duz]
    assert_equal 101, result[:ien]
    assert_equal 3, result[:user_class]
  end

  def test_practitioner_find_nil_for_unknown
    assert_nil RpmsRpc::Practitioner.find(99999)
  end

  def test_practitioner_search
    results = RpmsRpc::Practitioner.search("MARTINEZ")

    assert results.any?
    assert_equal "MARTINEZ,SARAH", results.first[:name]
  end

  # =============================================================================
  # REFERRAL
  # =============================================================================

  def test_referral_find
    result = RpmsRpc::Referral.find("SR-001")

    refute_nil result
    assert_equal "draft", result[:status]
  end

  def test_referral_find_nil_for_unknown
    assert_nil RpmsRpc::Referral.find("NONEXISTENT")
  end
end
