# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/allergy"
require "rpms_rpc/api/problem"
require "rpms_rpc/api/vital"
require "rpms_rpc/api/medication"
require "rpms_rpc/api/procedure"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/immunization"

# Tests for clinical data symbolic APIs.
class ClinicalDataApiTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      m.seed_collection(:allergy_list,
        [ { ien: 1, allergen: "Penicillin", reaction: "Hives", severity: "moderate" },
          { ien: 2, allergen: "Shellfish", reaction: "Anaphylaxis", severity: "severe" } ])
      m.seed_collection(:problem_list,
        [ { ien: 1, status: "A", icd_code: "E11.9", description: "Type 2 diabetes" },
          { ien: 2, status: "I", icd_code: "I10", description: "Hypertension" } ])
      m.seed_keyed_collection(:vitals, "1",
        [ { type: "BP", value: "120/80", units: "mm[Hg]" },
          { type: "HR", value: "72", units: "/min" } ])
      m.seed_collection(:medication_list,
        [ { ien: 1, drug_name: "Lisinopril 10mg", sig: "1 tab daily", status: "active" } ])
      m.seed(:medication_detail, "1", "Drug: Lisinopril 10mg\nSIG: Take 1 tablet by mouth daily\nStatus: Active\nRefills: 3")
      m.seed_collection(:procedure_list,
        [ { ien: 1, name: "CBC", date: Date.new(2026, 1, 15), status: "completed" } ])
      m.seed_collection(:patient_appointments,
        [ { datetime: Date.new(2026, 2, 1), location_ien: 1, location: "Primary Care", status: "scheduled" } ])
      m.seed(:immunization_text, "1", "01/15/2026  COVID-19 Vaccine  Pfizer  LOT-ABC  Site: Left Deltoid")
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # =============================================================================
  # ALLERGY
  # =============================================================================

  def test_allergy_for_patient_returns_array
    results = RpmsRpc::Allergy.for_patient("1")

    assert results.is_a?(Array)
    assert_equal 2, results.length
    assert_equal "Penicillin", results.first[:allergen]
  end

  def test_allergy_for_patient_returns_hashes_with_allergen
    results = RpmsRpc::Allergy.for_patient("1")

    results.each { |r| refute_nil r[:allergen] }
  end

  # =============================================================================
  # PROBLEM
  # =============================================================================

  def test_problem_for_patient_returns_array
    results = RpmsRpc::Problem.for_patient("1")

    assert results.is_a?(Array)
    assert_equal 2, results.length
    assert_equal "E11.9", results.first[:icd_code]
  end

  def test_problem_for_patient_returns_hashes_with_icd_code
    results = RpmsRpc::Problem.for_patient("1")

    results.each { |r| refute_nil r[:icd_code] }
  end

  # =============================================================================
  # VITAL
  # =============================================================================

  def test_vital_for_patient_returns_array
    results = RpmsRpc::Vital.for_patient("1")

    assert results.is_a?(Array)
    assert results.any? { |v| v[:type] == "BP" }
  end

  def test_vital_for_patient_empty_when_none
    results = RpmsRpc::Vital.for_patient("99999")

    assert_equal [], results
  end

  # =============================================================================
  # MEDICATION
  # =============================================================================

  def test_medication_for_patient_returns_array
    results = RpmsRpc::Medication.for_patient("1")

    assert results.is_a?(Array)
    assert_equal "Lisinopril 10mg", results.first[:drug_name]
  end

  def test_medication_find_returns_detail_text
    result = RpmsRpc::Medication.find(1)

    refute_nil result
    assert_includes result, "Lisinopril 10mg"
  end

  def test_medication_find_nil_for_unknown
    assert_nil RpmsRpc::Medication.find(99999)
  end

  # =============================================================================
  # PROCEDURE
  # =============================================================================

  def test_procedure_for_patient_returns_array
    results = RpmsRpc::Procedure.for_patient("1")

    assert results.is_a?(Array)
    assert_equal "CBC", results.first[:name]
  end

  # =============================================================================
  # ENCOUNTER
  # =============================================================================

  def test_encounter_for_patient_returns_array
    results = RpmsRpc::Encounter.for_patient("1")

    assert results.is_a?(Array)
    assert_equal "Primary Care", results.first[:location]
  end

  # =============================================================================
  # IMMUNIZATION
  # =============================================================================

  def test_immunization_for_patient_returns_text
    result = RpmsRpc::Immunization.for_patient("1")

    refute_nil result
    assert_includes result, "COVID-19"
  end

  def test_immunization_for_patient_nil_when_none
    result = RpmsRpc::Immunization.for_patient("99999")

    assert_nil result
  end
end
