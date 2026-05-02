# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/practitioner"
require "rpms_rpc/api/organization"
require "rpms_rpc/api/location"
require "rpms_rpc/api/referral"

# Tests for clinical data symbolic APIs.
class ClinicalTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      m.seed(:practitioner_info, "101", { name: "MARTINEZ,SARAH", title: "MD", specialty: "Cardiology", npi: "1234567890" })
      m.seed_collection(:practitioner_list,
        [ { ien: 101, name: "MARTINEZ,SARAH", title: "MD" } ],
        filter_field: :name)
      m.seed(:institution, "1", { ien: 1, name: "Alaska Native Medical Center", station_number: "463" })
      m.seed(:hospital_location, "1", { ien: 1, name: "Primary Care Clinic", abbreviation: "PCC" })
      m.seed(:referral_detail, "SR-001", { ien: "SR-001", status: "draft", patient_dfn: 1, type: "Cardiology" })
      m.seed(:referral_delete, "SR-001", { success: true, message: "Referral deleted" })
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # =============================================================================
  # PRACTITIONER
  # =============================================================================

  def test_practitioner_find
    result = RpmsRpc::Practitioner.find(101)

    refute_nil result
    assert_equal "MARTINEZ,SARAH", result[:name]
    assert_equal "1234567890", result[:npi]
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
  # ORGANIZATION
  # =============================================================================

  def test_organization_find
    result = RpmsRpc::Organization.find(1)

    refute_nil result
    assert_equal "Alaska Native Medical Center", result[:name]
  end

  def test_organization_find_nil_for_unknown
    assert_nil RpmsRpc::Organization.find(99999)
  end

  # =============================================================================
  # LOCATION
  # =============================================================================

  def test_location_find
    result = RpmsRpc::Location.find(1)

    refute_nil result
    assert_equal "Primary Care Clinic", result[:name]
  end

  def test_location_find_nil_for_unknown
    assert_nil RpmsRpc::Location.find(99999)
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

  def test_referral_delete
    result = RpmsRpc::Referral.delete("SR-001")

    refute_nil result
    assert result[:success]
  end
end
