# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/tribal"
require "rpms_rpc/api/eligibility"

# Tests for tribal/IHS symbolic APIs.
class TribalTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      m.seed(:tribal_enrollment, "1", { enrollment_number: "ANLC-12345", tribe_name: "Alaska Native", status: "ACTIVE" })
      m.seed(:tribal_validation, "ANLC-12345", { valid: true, tribe_code: "ANLC", status: "ACTIVE" })
      m.seed(:enrollment_eligibility, "1", { active: true, eligible_for_ihs: true, service_unit: "Anchorage" })
      m.seed(:service_unit, "1", { ien: 1, name: "Anchorage", region: "Alaska" })
      m.seed(:tribe_info, "ANLC", { ien: 100, name: "Alaska Native - Anchorage (ANLC)", code: "ANLC" })
      m.seed(:vfc_eligibility, "1", { code: "V04", label: "AI/AN" })
      m.seed_collection(:vfc_eligibility_list, [
        { code: "V01", label: "Not VFC eligible" },
        { code: "V04", label: "AI/AN" }
      ])
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_tribal_enrollment
    result = RpmsRpc::Tribal.enrollment(1)

    refute_nil result
    assert_equal "ANLC-12345", result[:enrollment_number]
  end

  def test_tribal_validate
    result = RpmsRpc::Tribal.validate("ANLC-12345")

    assert result[:valid]
    assert_equal "ANLC", result[:tribe_code]
  end

  def test_tribal_eligibility
    result = RpmsRpc::Tribal.eligibility(1)

    assert result[:active]
    assert result[:eligible_for_ihs]
  end

  def test_tribal_service_unit
    result = RpmsRpc::Tribal.service_unit(1)

    refute_nil result
    assert_equal "Anchorage", result[:name]
  end

  def test_tribal_tribe_info
    result = RpmsRpc::Tribal.tribe_info("ANLC")

    refute_nil result
    assert_equal "ANLC", result[:code]
  end

  def test_vfc_eligibility
    result = RpmsRpc::Eligibility.for_patient("1")

    refute_nil result
    assert_equal "V04", result[:code]
  end

  def test_vfc_eligibility_codes
    codes = RpmsRpc::Eligibility.codes

    assert codes.is_a?(Array)
    assert codes.any? { |c| c[:code] == "V04" }
  end
end
