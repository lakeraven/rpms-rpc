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
        [ { measurement_ien: 5001, type: "BP", recorded_date: Time.new(2026, 1, 15, 8, 0, 0), value: "120/80" },
          { measurement_ien: 5002, type: "HR", recorded_date: Time.new(2026, 1, 15, 8, 0, 0), value: "72" } ])
      m.seed_collection(:medication_list,
        [ { id: "403R;O", name: "Lisinopril 10mg", stop_date: Date.new(2027, 1, 1),
            route: "PO", schedule: "QD", refills: 3 } ])
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

  # "No problems" comes back as the sentinel row "^No problems found."
  # (LIST^ORQQPL: ORQQPL.m:17) — piece 1 empty, so :ien is blank and the
  # row must be dropped, not surfaced as a phantom problem.
  def test_problem_for_patient_drops_no_problems_sentinel_row
    client = RpmsRpc::MockClient.new
    def client.call_rpc(_rpc, *_params) = [ "^No problems found." ]
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }

    assert_equal [], RpmsRpc::Problem.for_patient("1")
  ensure
    RpmsRpc.reset!
  end

  # =============================================================================
  # VITAL
  # =============================================================================

  def test_vital_for_patient_returns_array
    results = RpmsRpc::Vital.for_patient("1")

    assert results.is_a?(Array)
    assert results.any? { |v| v[:type] == "BP" }
  end

  # The registered "ORQQVI VITALS" dispatches to FASTVIT^ORQQVI
  # (.broker_dumps_8994_20260607.txt:565) — rows are "vital measurement
  # ien^vital type^rate^date/time taken" (ORQQVI.m:66-67, rows :113/:179):
  # VALUE at piece 3, DATETIME at piece 4. The prior mapping declared
  # IEN^TYPE^DATETIME^VALUE — the shape of VITALS^ORQQVI (dump line 795,
  # a different RPC), i.e. it was verified against the wrong routine tag
  # and swapped value/date.
  def test_vitals_mapping_parses_real_fastvit_row
    row = RpmsRpc::DataMapper[:vitals].parse_one("5001^BP^120/80^3250115.08")

    assert_equal 5001,     row[:measurement_ien]
    assert_equal "BP",     row[:type]
    assert_equal "120/80", row[:value]
    assert_equal Time.new(2025, 1, 15, 8, 0, 0), row[:recorded_date]
  end

  # Date-only date/time values must not be dropped by the datetime coercion.
  def test_vitals_mapping_parses_date_only_datetime
    row = RpmsRpc::DataMapper[:vitals].parse_one("5001^WT^180^3250115")

    refute_nil row[:recorded_date]
    assert_equal 2025, row[:recorded_date].year
  end

  # FASTVIT emits no sentinel row (that belongs to VITALS^ORQQVI,
  # ORQQVI.m:24) — but a row without a measurement IEN must still be
  # dropped defensively, never surfaced as a record.
  def test_vital_for_patient_drops_rows_without_measurement_ien
    RpmsRpc.reset!
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:vitals, "7", [ { type: "No vitals found." } ])
    end

    assert_equal [], RpmsRpc::Vital.for_patient("7")
  end

  def test_vital_for_patient_empty_when_none
    results = RpmsRpc::Vital.for_patient("99999")

    assert_equal [], results
  end

  # Invalid DFNs must short-circuit to [] without dispatching an RPC
  # (Copilot finding: nil.to_s => "" used to reach the broker).
  def test_vital_for_patient_invalid_dfn_does_not_dispatch
    with_raising_client do
      assert_equal [], RpmsRpc::Vital.for_patient(nil)
      assert_equal [], RpmsRpc::Vital.for_patient("")
      assert_equal [], RpmsRpc::Vital.for_patient("   ")
      assert_equal [], RpmsRpc::Vital.for_patient(0)
      assert_equal [], RpmsRpc::Vital.for_patient(-3)
    end
  end

  def test_problem_for_patient_invalid_dfn_does_not_dispatch
    with_raising_client do
      assert_equal [], RpmsRpc::Problem.for_patient(nil)
      assert_equal [], RpmsRpc::Problem.for_patient("")
      assert_equal [], RpmsRpc::Problem.for_patient(0)
    end
  end

  def test_medication_for_patient_invalid_dfn_does_not_dispatch
    with_raising_client do
      assert_equal [], RpmsRpc::Medication.for_patient(nil)
      assert_equal [], RpmsRpc::Medication.for_patient("")
      assert_equal [], RpmsRpc::Medication.for_patient(-1)
    end
  end

  # =============================================================================
  # MEDICATION
  # =============================================================================

  def test_medication_for_patient_returns_array
    results = RpmsRpc::Medication.for_patient("1")

    assert results.is_a?(Array)
    assert_equal "Lisinopril 10mg", results.first[:name]
    assert_equal "403R;O", results.first[:id]
  end

  # "No medications" comes back as the sentinel row
  # "^No medications found." (LIST^ORQQPS: ORQQPS.m:53) — no id, so it
  # must be dropped, not surfaced as a phantom medication.
  def test_medication_for_patient_drops_no_medications_sentinel_row
    client = RpmsRpc::MockClient.new
    def client.call_rpc(_rpc, *_params) = [ "^No medications found." ]
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }

    assert_equal [], RpmsRpc::Medication.for_patient("1")
  ensure
    RpmsRpc.reset!
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

  def test_immunization_text_summary_returns_text
    result = RpmsRpc::Immunization.text_summary("1")
    flattened = Array(result).join("\n")

    refute_nil result
    assert_includes flattened, "COVID-19"
  end

  def test_immunization_for_patient_returns_empty_when_none
    # Structured list semantics: no seeded :immunization_list rows → [].
    assert_equal [], RpmsRpc::Immunization.for_patient("99999")
  end

  def test_immunization_for_patient_returns_structured_records_when_seeded
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:immunization_list, "1", [
        { ien: 7001, vaccine_code: "207", vaccine_display: "COVID-19 Pfizer",
          status: "completed", lot_number: "EX1234" }
      ])
    end

    result = RpmsRpc::Immunization.for_patient("1")

    assert_equal 1, result.length
    assert_equal "207", result.first[:vaccine_code]
    assert_equal "EX1234", result.first[:lot_number]
  end

  private

  # Swap in a client that fails on ANY RPC dispatch — proves a guard
  # short-circuited before reaching the broker.
  def with_raising_client
    client = RpmsRpc::MockClient.new
    def client.call_rpc(rpc, *_params)
      raise "RPC dispatched for invalid identifier: #{rpc}"
    end
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
    yield
  ensure
    RpmsRpc.reset!
  end
end
