# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/allergy"
require "rpms_rpc/api/problem"
require "rpms_rpc/api/vital"
require "rpms_rpc/api/medication"
require "rpms_rpc/api/encounter"
require_relative "../captured_replies"

# The chart list reads, against the replies a fresh rpms-ydb container sent
# for its demo patients (test/fixtures/captured_replies/clinical-data.yml),
# replayed through CiaClient.
class ClinicalDataApiTest < Minitest::Test
  SLUG = "clinical-data"

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def capture(name) = CapturedReplies.raw(SLUG, name)

  # =============================================================================
  # ALLERGY
  # =============================================================================

  def test_allergy_for_patient_reads_each_row
    client = replay("ORQQAL LIST" => [ capture("allergies_dfn_2") ])

    assert_equal [ { ien: "1", allergen: "PENICILLIN", severity: nil, signs: "HIVES", altered: false } ],
                 RpmsRpc::Allergy.for_patient("2")
    assert_equal [ { rpc: "ORQQAL LIST", params: [ "2" ] } ], client.calls
  end

  def test_allergy_for_patient_row_without_a_sign
    replay("ORQQAL LIST" => [ capture("allergies_dfn_4") ])

    assert_equal [ { ien: "2", allergen: "BEE POLLEN", severity: nil, signs: nil, altered: false } ],
                 RpmsRpc::Allergy.for_patient("4")
  end

  # "^No Allergy Assessment" (ORQQAL.m:12) is a state, not an allergy.
  def test_allergy_for_an_unassessed_patient_is_empty_and_not_assessed
    replay("ORQQAL LIST" => [ capture("allergies_unassessed") ])

    assert_equal({ assessed: false, nka: false, allergies: [] }, RpmsRpc::Allergy.assessment("1"))
  end

  # =============================================================================
  # PROBLEM
  # =============================================================================

  # Demo patient 2's problems carry ICD-10 codes, which this build's
  # LIST^GMPLUTL2 answers with $$ICDDX error text in piece 4 and marks '#'.
  def test_problem_for_patient_reads_each_row
    client = replay("ORQQPL LIST" => [ capture("problems_dfn_2") ])

    rows = RpmsRpc::Problem.for_patient("2")

    assert_equal [ "1", "2" ], rows.map { |r| r[:ien] }
    first = rows.first
    assert_equal "*TYPE 2 DIABETES MELLITUS", first[:description]
    assert_equal "A", first[:status]
    assert_equal Date.new(2023, 4, 10), first[:onset_date]
    assert first[:inactive_icd]
    assert_nil first[:icd_code], "the $$ICDDX error text is not a code"
    assert_equal [ { rpc: "ORQQPL LIST", params: [ "2", "" ] } ], client.calls
  end

  # "No problems" comes back as the sentinel row "^No problems found."
  # (LIST^ORQQPL: ORQQPL.m:17): piece 1 empty, so it is dropped, not
  # surfaced as a phantom problem.
  def test_problem_for_patient_drops_no_problems_sentinel_row
    replay("ORQQPL LIST" => [ capture("problems_none") ])

    assert_equal [], RpmsRpc::Problem.for_patient("1")
  end

  # =============================================================================
  # VITAL
  # =============================================================================

  # The registered "ORQQVI VITALS" dispatches to FASTVIT^ORQQVI: rows are
  # "vital measurement ien^vital type^rate^date/time taken" (ORQQVI.m:66-67),
  # VALUE at piece 3, DATETIME at piece 4.
  def test_vital_for_patient_reads_fastvit_rows
    client = replay("ORQQVI VITALS" => [ capture("vitals_dfn_4") ])

    rows = RpmsRpc::Vital.for_patient("4")

    assert_equal %w[TMP PU RS BP PA O2], rows.map { |r| r[:type] }
    bp = rows.find { |r| r[:type] == "BP" }
    assert_equal 8, bp[:measurement_ien]
    assert_equal "117/81", bp[:value]
    assert_equal Time.new(2026, 9, 11, 21, 34, 0), bp[:recorded_date]
    temp = rows.first
    assert_equal "98", temp[:value]
    assert_equal "98 F", temp[:display]
    assert_equal "(36.7 C)", temp[:metric_display]
    assert_equal [ { rpc: "ORQQVI VITALS", params: [ "4" ] } ], client.calls, "no dates: DFN alone"
  end

  def test_vital_for_patient_empty_when_none
    replay("ORQQVI VITALS" => [ capture("vitals_none") ])

    assert_equal [], RpmsRpc::Vital.for_patient("99999")
  end

  # Invalid DFNs short-circuit to [] without dispatching an RPC.
  def test_vital_for_patient_invalid_dfn_does_not_dispatch
    client = replay({})

    [ nil, "", "   ", 0, -3 ].each { |dfn| assert_equal [], RpmsRpc::Vital.for_patient(dfn) }
    assert_empty client.calls
  end

  def test_problem_for_patient_invalid_dfn_does_not_dispatch
    client = replay({})

    [ nil, "", 0 ].each { |dfn| assert_equal [], RpmsRpc::Problem.for_patient(dfn) }
    assert_empty client.calls
  end

  def test_medication_for_patient_invalid_dfn_does_not_dispatch
    client = replay({})

    [ nil, "", -1 ].each { |dfn| assert_equal [], RpmsRpc::Medication.for_patient(dfn) }
    assert_empty client.calls
  end

  # =============================================================================
  # MEDICATION
  # =============================================================================

  # "No medications" comes back as the sentinel row "^No medications found."
  # (LIST^ORQQPS: ORQQPS.m:53): no id, so it is dropped, not surfaced as a
  # phantom medication. No demo patient on the build has a medication, so no
  # capture holds a medication row.
  def test_medication_for_patient_drops_no_medications_sentinel_row
    client = replay("ORQQPS LIST" => [ capture("medications_none") ])

    assert_equal [], RpmsRpc::Medication.for_patient("4")
    assert_equal [ { rpc: "ORQQPS LIST", params: [ "4", "", "" ] } ], client.calls
  end

  # Medication.find sends DETAIL(ORY,ORPT,ORMED)^ORQQPS one parameter, and the
  # build dies in M on the missing ORMED (rpms-rpc#678). The error is raised,
  # never read as detail text.
  def test_medication_find_raises_the_builds_m_error_for_its_one_parameter_frame
    replay("ORQQPS DETAIL" => [ capture("medication_detail_one_param") ])

    error = assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Medication.find(1) }
    assert_includes error.message, "DETAIL+2^ORQQPS"
  end

  def test_medication_find_invalid_ien_does_not_dispatch
    client = replay({})

    assert_nil RpmsRpc::Medication.find(nil)
    assert_nil RpmsRpc::Medication.find(0)
    assert_empty client.calls
  end

  # =============================================================================
  # ENCOUNTER
  # =============================================================================

  def test_encounter_for_patient_empty_when_no_appointments
    client = replay("ORWPT APPTLST" => [ capture("appointments_dfn_4") ])

    assert_equal [], RpmsRpc::Encounter.for_patient("4")
    assert_equal [ { rpc: "ORWPT APPTLST", params: [ "4" ] } ], client.calls
  end

  # When the scheduling read fails (DFN 1 holds no patient on the build), APPTLST
  # answers SDA^ORQRY01's one row with no time, "^Error encountered^Error
  # encountered". It is an error, never an appointment (rpms-rpc#679).
  def test_encounter_for_patient_raises_on_the_scheduling_error_row
    client = replay("ORWPT APPTLST" => [ capture("appointments_dfn_1") ])

    error = assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Encounter.for_patient("1") }
    assert_equal "ORWPT APPTLST could not read appointments for patient 1: Error encountered", error.message
    assert_equal [ { rpc: "ORWPT APPTLST", params: [ "1" ] } ], client.calls
  end
end
