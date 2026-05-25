# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/eligibility"

class EligibilityTest < Minitest::Test
  NIL_ELIGIBILITY = { code: nil, label: nil }.freeze

  def setup
    RpmsRpc.mock! do |m|
      m.seed(:vfc_eligibility, "1", { code: "V04", label: "American Indian/Alaska Native" })
      m.seed_collection(:vfc_eligibility_list, [
        { code: "V01", label: "Not VFC Eligible" },
        { code: "V04", label: "American Indian/Alaska Native" },
        { code: "V07", label: "Local-specific eligibility" }
      ])
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_for_patient_returns_patient_eligibility
    result = RpmsRpc::Eligibility.for_patient("1")

    assert_equal "V04", result[:code]
    assert_equal "American Indian/Alaska Native", result[:label]
  end

  def test_for_patient_returns_nil_hash_for_empty_response
    RpmsRpc.reset!
    RpmsRpc.mock!

    assert_equal NIL_ELIGIBILITY, RpmsRpc::Eligibility.for_patient("1")
  end

  def test_for_patient_returns_nil_hash_for_invalid_dfn
    assert_equal NIL_ELIGIBILITY, RpmsRpc::Eligibility.for_patient(nil)
    assert_equal NIL_ELIGIBILITY, RpmsRpc::Eligibility.for_patient("")
  end

  def test_for_patient_returns_nil_hash_for_unknown_dfn
    assert_equal NIL_ELIGIBILITY, RpmsRpc::Eligibility.for_patient("99999")
  end

  def test_codes_returns_all_eligibility_codes
    codes = RpmsRpc::Eligibility.codes

    assert_equal 3, codes.length
    assert_equal({ code: "V01", label: "Not VFC Eligible" }, codes.first)
    assert codes.any? { |code| code[:code] == "V07" }
  end
end
