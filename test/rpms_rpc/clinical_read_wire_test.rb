# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/allergy"
require "rpms_rpc/api/patient"

# Regression tests for issue #218: the four clinical reads feeding FHIR
# resources (Condition / Observation / MedicationRequest / AllergyIntolerance)
# plus Patient.find. Every fixture below is derived from the M routine's
# actual write statement (routine:line cited per test).
class ClinicalReadWireTest < Minitest::Test
  # Canned-response broker: returns one fixed response for every RPC.
  class RawResponseClient
    def initialize(response) = @response = response
    def supports?(*) = true
    def call_rpc(*) = @response
  end

  def teardown
    RpmsRpc.reset!
  end

  def stub_broker_response(response)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = RawResponseClient.new(response) }
  end

  # -- ORQQPL LIST (finding 1) ---------------------------------------------
  # LIST^ORQQPL reorders LIST^GMPLUTL2 rows (ORQQPL.m:14); the underlying row
  # is IFN^ST^NARR^ICD^ONSET^LASTMOD^SC^SP (GMPLUTL3.m:120), so the wire is
  # IEN^NARRATIVE^STATUS^ICD^ONSET^LASTMOD^SC^SPEXP.

  def test_problem_list_row_matches_orqqpl_wire_order
    row = RpmsRpc::DataMapper[:problem_list].parse_many(
      [ "123^Type 2 diabetes mellitus^A^E11.9^3200101^3250301.1015^NSC^^^^^1" ]
    ).first

    assert_equal "123", row[:ien]
    assert_equal "Type 2 diabetes mellitus", row[:description],
      "piece 2 is the provider narrative (GMPLUTL3.m:114,120)"
    assert_equal "A", row[:status],
      "piece 3 is the status code (GMPLUTL3.m:110,120)"
    assert_equal "E11.9", row[:icd_code]
    assert_equal Date.new(2020, 1, 1), row[:onset_date]
    assert_equal Date.new(2025, 3, 1), row[:last_modified],
      "piece 6 is date-last-modified (GMPLUTL3.m:109,120), not a recorded date"
    assert_equal "NSC", row[:service_connected],
      "piece 7 is SC/NSC (GMPLUTL3.m:111,120), not a provider DUZ"
  end

  def test_problem_list_no_problems_sentinel_yields_no_rows
    # ORQQPL.m:17: S:+$G(ORPY(1))<1 ORPY(1)="^No problems found."
    assert_equal [], RpmsRpc::DataMapper[:problem_list].parse_many([ "^No problems found." ])
  end

  def test_problem_list_unavailable_sentinel_yields_no_rows
    # ORQQPL.m:18: "^Problem list not available.^"
    assert_equal [], RpmsRpc::DataMapper[:problem_list].parse_many([ "^Problem list not available.^" ])
  end

  # -- ORQQVI VITALS (finding 2) -------------------------------------------
  # VITALS^ORQQVI row: "vital measurement ien^vital type^date/time taken^rate"
  # (ORQQVI.m:6, written at ORQQVI.m:23).

  def test_vitals_row_matches_orqqvi_wire_order
    row = RpmsRpc::DataMapper[:vitals].parse_many([ "8001^BP^3260401.0815^120/80" ]).first

    assert_equal "8001", row[:ien], "piece 1 is the measurement IEN (ORQQVI.m:23)"
    assert_equal "BP", row[:type], "piece 2 is the vital type abbreviation (ORQQVI.m:23)"
    assert_equal Time.new(2026, 4, 1, 8, 15), row[:recorded_date],
      "piece 3 is the date/time taken (ORQQVI.m:23)"
    assert_equal "120/80", row[:value], "piece 4 is the rate (ORQQVI.m:23)"
  end

  def test_vitals_no_vitals_sentinel_yields_no_rows
    # ORQQVI.m:24: I I=0 S ORY(1)="^No vitals found."
    assert_equal [], RpmsRpc::DataMapper[:vitals].parse_many([ "^No vitals found." ])
  end

  # -- ORQQPS LIST (finding 3) ---------------------------------------------
  # LIST^ORQQPS row: "id^nameform^stop date^route^schedule/infusion rate^
  # refills remaining" (ORQQPS.m:5; outpatient row built at ORQQPS.m:47).

  def test_medication_list_row_matches_orqqps_wire_order
    row = RpmsRpc::DataMapper[:medication_list].parse_many(
      [ "5100;O^LISINOPRIL 10MG TAB^3270115^PO^QD^2" ]
    ).first

    assert_equal "5100;O", row[:ien]
    assert_equal "LISINOPRIL 10MG TAB", row[:drug_name]
    assert_equal Date.new(2027, 1, 15), row[:stop_date],
      "piece 3 is the stop date (ORQQPS.m:5), not a sig"
    assert_equal "PO", row[:route], "piece 4 is the med route (ORQQPS.m:13-16,47)"
    assert_equal "QD", row[:schedule], "piece 5 is the schedule (ORQQPS.m:17-20,47)"
    assert_equal 2, row[:refills], "piece 6 is refills remaining (ORQQPS.m:47)"
  end

  def test_medication_list_no_medications_sentinel_yields_no_rows
    # ORQQPS.m:53: S:+$G(ORY(1))<1 ORY(1)="^No medications found."
    assert_equal [], RpmsRpc::DataMapper[:medication_list].parse_many([ "^No medications found." ])
  end

  # -- ORQQAL LIST (finding 4) ---------------------------------------------
  # LIST^ORQQAL row: allergy ien^agent^severity^signs (ORQQAL.m:14 emits
  # $P(GMRARXN(J),U,3)^$P(J,U)^$P(J,U,2) over EN1^GMRAOR1 rows of
  # agent^severity^ien; SIGNS appends ";"-joined signs — ORQQAL.m:18-21).

  def test_allergy_list_row_matches_orqqal_wire_order
    row = RpmsRpc::DataMapper[:allergy_list].parse_many(
      [ "667^PENICILLIN^SEVERE^HIVES;ANAPHYLAXIS" ]
    ).first

    assert_equal "667", row[:ien], "piece 1 is the allergy IEN (ORQQAL.m:14)"
    assert_equal "PENICILLIN", row[:allergen], "piece 2 is the causative agent (ORQQAL.m:14)"
    assert_equal "SEVERE", row[:severity], "piece 3 is the severity (GMRAOR1.m EN1)"
    assert_equal "HIVES;ANAPHYLAXIS", row[:signs],
      "piece 4 is the \";\"-joined signs/symptoms (ORQQAL.m:18-21)"
  end

  def test_allergy_sentinels_never_parse_as_allergy_records
    # ORQQAL.m:12-13,15 — assessment-state markers, not allergies.
    [ "^No Allergy Assessment", "^No Known Allergies", "^No allergies found." ].each do |sentinel|
      assert_equal [], RpmsRpc::DataMapper[:allergy_list].parse_many([ sentinel ]),
        "#{sentinel.inspect} must not surface as an allergy record"
    end
  end

  # -- Allergy.assessment three-state contract ------------------------------

  def test_allergy_assessment_not_assessed
    stub_broker_response([ "^No Allergy Assessment" ])

    result = RpmsRpc::Allergy.assessment("42")
    assert_equal({ assessed: false, nka: false, allergies: [] }, result)
  end

  def test_allergy_assessment_no_known_allergies
    stub_broker_response([ "^No Known Allergies" ])

    result = RpmsRpc::Allergy.assessment("42")
    assert_equal({ assessed: true, nka: true, allergies: [] }, result)
  end

  def test_allergy_assessment_with_allergies
    stub_broker_response([ "667^PENICILLIN^SEVERE^HIVES" ])

    result = RpmsRpc::Allergy.assessment("42")
    assert result[:assessed]
    refute result[:nka]
    assert_equal 1, result[:allergies].length
    assert_equal "PENICILLIN", result[:allergies].first[:allergen]
  end

  def test_allergy_for_patient_returns_no_records_for_nka_patient
    stub_broker_response([ "^No Known Allergies" ])

    assert_equal [], RpmsRpc::Allergy.for_patient("42"),
      "an NKA patient must not appear to HAVE an allergy named 'No Known Allergies'"
  end

  # -- ORWPT SELECT -1 guard (finding 5) ------------------------------------

  def test_patient_select_unknown_dfn_error_line_parses_nil
    # SELECT^ORWPT for a missing DFN: REC="-1^^^^^Patient is unknown to CPRS."
    # (ORWPT.m:49)
    assert_nil RpmsRpc::DataMapper[:patient_select].parse_one("-1^^^^^Patient is unknown to CPRS.")
  end

  def test_patient_find_returns_nil_for_unknown_dfn
    stub_broker_response("-1^^^^^Patient is unknown to CPRS.")

    assert_nil RpmsRpc::Patient.find(999_999)
  end

  def test_parse_many_skips_error_rows_inside_arrays
    lines = [ "-1^No data found.", "667^PENICILLIN^SEVERE^HIVES" ]
    rows = RpmsRpc::DataMapper[:allergy_list].parse_many(lines)
    assert_equal 1, rows.length
    assert_equal "PENICILLIN", rows.first[:allergen]
  end
end
