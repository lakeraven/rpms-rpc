# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/patient"

# Tests for RpmsRpc::Patient symbolic API.
# Engine code calls these methods instead of DataMapper directly.
class PatientTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      m.seed(:patient_select, "1", { name: "DOE,JOHN", sex: "M", dob: Date.new(1980, 1, 15), ssn: "111223333", age: 45 })
      m.seed(:patient_id_info, "1", {
        ssn: "111223333", dob: Date.new(1980, 1, 15), sex: "M",
        race_code: "I", site_ien: 7819, name: "DOE,JOHN"
      })
      m.seed(:patient_ssn, "111-22-3333", { dfn: 1, name: "DOE,JOHN", ssn: "111-22-3333" })
      m.seed_collection(:patient_list,
        [ { dfn: 1, name: "DOE,JOHN", sex: "M" }, { dfn: 2, name: "SMITH,JANE", sex: "F" } ],
        filter_field: :name)
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # =============================================================================
  # FIND
  # =============================================================================

  def test_find_returns_hash_with_demographics
    result = RpmsRpc::Patient.find(1)

    refute_nil result
    assert_equal "DOE,JOHN", result[:name]
    assert_equal "M", result[:sex]
  end

  def test_find_merges_identifier_fields
    result = RpmsRpc::Patient.find(1)

    # ORWPT ID INFO contributes the site IEN and race code to the merge.
    # Extended demographics (address, city, state, phone, tribal, etc.)
    # come from the BHDPTRPC family — not present on staging; see rr-6jr.
    assert_equal "I", result[:race_code]
    assert_equal 7819, result[:site_ien]
  end

  def test_find_returns_nil_for_unknown
    assert_nil RpmsRpc::Patient.find(99999)
  end

  def test_find_returns_nil_for_nil
    assert_nil RpmsRpc::Patient.find(nil)
  end

  # =============================================================================
  # SEARCH
  # =============================================================================

  def test_search_returns_array
    results = RpmsRpc::Patient.search("DOE")

    assert results.is_a?(Array)
    assert_equal 1, results.length
    assert_equal "DOE,JOHN", results.first[:name]
  end

  def test_search_returns_empty_for_no_match
    results = RpmsRpc::Patient.search("ZZZZZ")

    assert_equal [], results
  end

  # =============================================================================
  # FIND BY SSN
  # =============================================================================

  def test_find_by_ssn_returns_hash
    result = RpmsRpc::Patient.find_by_ssn("111-22-3333")

    refute_nil result
    assert_equal 1, result[:dfn]
  end

  def test_find_by_ssn_returns_nil_for_unknown
    assert_nil RpmsRpc::Patient.find_by_ssn("000-00-0000")
  end

  # =============================================================================
  # REGISTER
  # =============================================================================

  NEW_PATIENT = { name: "Raven,Nora", dob: Date.new(1992, 3, 11), sex: "F", ssn: "555-01-2345" }.freeze

  def seed_register_response(attrs, success:, payload:)
    key = RpmsRpc::Patient.registration_param(attrs)
    RpmsRpc.client.seed(:patient_register, key, { success: success, dfn_or_error: payload })
  end

  def test_register_success_returns_dfn
    seed_register_response(NEW_PATIENT, success: true, payload: "42")

    result = RpmsRpc::Patient.register(NEW_PATIENT)

    assert result[:success]
    assert_equal 42, result[:dfn]
  end

  def test_register_formats_param_as_name_sex_fileman_dob_ssn
    seed_register_response(NEW_PATIENT, success: true, payload: "42")

    RpmsRpc::Patient.register(NEW_PATIENT)

    call = RpmsRpc.client.received_calls.last
    assert_equal "BHDPTRPC REGISTER", call[:rpc]
    # Name/sex upcased, DOB in FileMan form (2920311 = 1992-03-11), SSN dashes stripped.
    assert_equal "RAVEN,NORA^F^2920311^555012345", call[:params].first
  end

  def test_register_failure_returns_error_message
    seed_register_response(NEW_PATIENT, success: false, payload: "Patient with this SSN already exists")

    result = RpmsRpc::Patient.register(NEW_PATIENT)

    refute result[:success]
    assert_match(/already exists/, result[:error])
  end

  def test_register_returns_nil_when_broker_gives_no_response
    # Nothing seeded for this param — mock returns "" (no response).
    assert_nil RpmsRpc::Patient.register(NEW_PATIENT)
  end

  def test_register_accepts_preformatted_dob_string
    attrs = NEW_PATIENT.merge(dob: "2920311")
    seed_register_response(attrs, success: true, payload: "43")

    result = RpmsRpc::Patient.register(attrs)

    assert result[:success]
    assert_equal 43, result[:dfn]
  end
end
