# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/rpms_rpc/mock_fhir_client"

class RpmsRpc::MockFhirClientTest < Minitest::Test
  def setup
    @client = RpmsRpc::MockFhirClient.new

    @client.seed_resource("Patient", "1", {
      resourceType: "Patient", id: "1",
      name: [{ family: "Anderson", given: ["Alice"] }],
      gender: "female", birthDate: "1980-05-15",
      identifier: [
        { system: "urn:oid:2.16.840.1.113883.4.349", value: "1" },
        { system: "http://hl7.org/fhir/sid/us-ssn", value: "111-11-1111" }
      ]
    })

    @client.seed_resource("Patient", "2", {
      resourceType: "Patient", id: "2",
      name: [{ family: "Mouse", given: ["Mickey", "M"] }],
      gender: "male", birthDate: "2010-02-14"
    })

    @client.seed_resource("Patient", "3", {
      resourceType: "Patient", id: "3",
      name: [{ family: "Doe", given: ["Jane"] }],
      gender: "female", birthDate: "1990-12-25"
    })

    @client.seed_resource("Observation", "101", {
      resourceType: "Observation", id: "101",
      subject: { reference: "Patient/1" },
      code: { text: "Blood Pressure" },
      valueQuantity: { value: 120, unit: "mmHg" }
    })
  end

  # -- read -------------------------------------------------------------------

  def test_read_existing_resource
    result = @client.read("Patient", "1")
    assert_equal "Patient", result["resourceType"]
    assert_equal "1", result["id"]
    assert_equal "Anderson", result.dig("name", 0, "family")
  end

  def test_read_nonexistent_resource
    result = @client.read("Patient", "999")
    assert_equal "OperationOutcome", result["resourceType"]
    assert_equal "not-found", result.dig("issue", 0, "code")
  end

  def test_read_nonexistent_type
    result = @client.read("Encounter", "1")
    assert_equal "OperationOutcome", result["resourceType"]
  end

  # -- search by name ---------------------------------------------------------

  def test_search_by_name_family
    result = @client.search("Patient", name: "Anderson")
    assert_equal "Bundle", result["resourceType"]
    assert_equal 1, result["total"]
    assert_equal "1", result.dig("entry", 0, "resource", "id")
  end

  def test_search_by_name_partial
    result = @client.search("Patient", name: "And")
    assert_equal 1, result["total"]
  end

  def test_search_by_name_case_insensitive
    result = @client.search("Patient", name: "anderson")
    assert_equal 1, result["total"]
  end

  def test_search_by_name_no_match
    result = @client.search("Patient", name: "Nonexistent")
    assert_equal 0, result["total"]
    assert_empty result["entry"]
  end

  # -- search by identifier ---------------------------------------------------

  def test_search_by_identifier
    result = @client.search("Patient", identifier: "111-11-1111")
    assert_equal 1, result["total"]
    assert_equal "1", result.dig("entry", 0, "resource", "id")
  end

  # -- search by _id ----------------------------------------------------------

  def test_search_by_id
    result = @client.search("Patient", _id: "2")
    assert_equal 1, result["total"]
    assert_equal "2", result.dig("entry", 0, "resource", "id")
  end

  # -- search by patient (for clinical resources) -----------------------------

  def test_search_by_patient_reference
    result = @client.search("Observation", patient: "1")
    assert_equal 1, result["total"]
    assert_equal "Blood Pressure", result.dig("entry", 0, "resource", "code", "text")
  end

  def test_search_by_patient_no_match
    result = @client.search("Observation", patient: "999")
    assert_equal 0, result["total"]
  end

  # -- search with no params (return all) -------------------------------------

  def test_search_all
    result = @client.search("Patient")
    assert_equal 3, result["total"]
  end

  # -- search nonexistent type ------------------------------------------------

  def test_search_empty_type
    result = @client.search("Encounter")
    assert_equal 0, result["total"]
  end

  # -- search with multiple params --------------------------------------------

  def test_search_multiple_params
    result = @client.search("Patient", name: "Anderson", gender: "female")
    assert_equal 1, result["total"]
  end

  def test_search_multiple_params_no_match
    result = @client.search("Patient", name: "Anderson", gender: "male")
    assert_equal 0, result["total"]
  end

  # -- bundle format ----------------------------------------------------------

  def test_bundle_format
    result = @client.search("Patient", name: "Anderson")
    assert_equal "Bundle", result["resourceType"]
    assert_equal "searchset", result["type"]
    assert_equal 1, result["total"]
    assert_kind_of Array, result["entry"]
    assert result.dig("entry", 0, "resource")
  end

  # -- string keys in output --------------------------------------------------

  def test_output_uses_string_keys
    result = @client.read("Patient", "1")
    assert result.key?("resourceType"), "Expected string keys in output"
    refute result.key?(:resourceType), "Expected no symbol keys in output"
  end
end
