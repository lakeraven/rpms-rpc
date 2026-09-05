# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/encounter"

class EncounterTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      # Existing read API
      m.seed_keyed_collection(:patient_appointments, "26664", [
        { datetime: nil, location_ien: 1608, location: "PS CLINICS", status: "scheduled" }
      ])

      # Open: BEHOENCX GETVISIT — visit_ien -> visit detail
      m.seed(:encounter_visit, "2090061", {
        location_ien: 1608,
        datetime_raw: "3260514.1907",
        status: "A",
        patient_dfn: 26664,
        ward: "2D309-PAH"
      })

      # Open: BEHOENCX FETCH — hydrated visit context
      m.seed(:encounter_fetch, "2090061", {
        clinic_name:    "PS CLINICS",
        clinic_abbrev:  "PSCL",
        location_ien:   1608,
        provider:       "SAND,ASH",
        visit_ien:      2090061,
        ward:           "2D309-PAH"
      })

      # Open: BEHOENCX CHKVISIT — missing-component report (multi-line)
      m.seed_keyed_collection(:encounter_chkvisit, "2090061", [
        { component: "POV", message: "Visit has no note" },
        { component: "E&M", message: "Visit has no note" }
      ])
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_open_returns_hydrated_encounter_context
    result = RpmsRpc::Encounter.open(26664, 2090061)

    refute_nil result, "Encounter.open should return a hash"
    assert_equal 2090061, result[:visit_ien]
    assert_equal 26664,   result[:patient_dfn]
    assert_equal 1608,    result[:location_ien]
    assert_equal "PS CLINICS", result[:location]
    assert_equal "SAND,ASH",   result[:provider]
    assert_equal "A", result[:status]
    assert_equal "3260514.1907", result[:datetime_raw]
    assert_equal "2D309-PAH",  result[:ward]
  end

  def test_open_reports_missing_components
    result = RpmsRpc::Encounter.open(26664, 2090061)

    refute_nil result[:missing_components]
    assert_equal 2, result[:missing_components].length
    assert_includes result[:missing_components].map { |c| c[:component] }, "POV"
    assert_includes result[:missing_components].map { |c| c[:component] }, "E&M"
  end

  def test_open_returns_nil_for_unknown_visit
    assert_nil RpmsRpc::Encounter.open(26664, 99999999)
  end

  def test_open_returns_nil_for_nil_dfn_or_visit_ien
    assert_nil RpmsRpc::Encounter.open(nil, 2090061)
    assert_nil RpmsRpc::Encounter.open(26664, nil)
  end

  # Cross-patient guard: visit 2090061 belongs to dfn 26664. A caller passing
  # any other dfn must not get the hydrated context — opening another
  # patient's chart by visit IEN would be a data-access leak.
  def test_open_returns_nil_when_visit_belongs_to_different_dfn
    assert_nil RpmsRpc::Encounter.open(99999, 2090061)
    assert_nil RpmsRpc::Encounter.open(0,     2090061)
  end

  # If BEHOENCX FETCH is missing, we have only partial context (no clinic
  # name, no provider). Treat as miss rather than returning a half-filled hash.
  def test_open_returns_nil_when_fetch_response_is_missing
    RpmsRpc.reset!
    RpmsRpc.mock! do |m|
      m.seed(:encounter_visit, "2090061", {
        location_ien: 1608, datetime_raw: "3260514.1907", status: "A",
        patient_dfn: 26664, ward: "2D309-PAH"
      })
      # Intentionally no :encounter_fetch seed
      m.seed_keyed_collection(:encounter_chkvisit, "2090061", [])
    end
    assert_nil RpmsRpc::Encounter.open(26664, 2090061)
  end

  def test_for_patient_still_works
    # Regression: the existing read API is unchanged.
    appointments = RpmsRpc::Encounter.for_patient("26664")
    assert_kind_of Array, appointments
    refute appointments.empty?
    assert_equal "PS CLINICS", appointments.first[:location]
  end

  # ===========================================================================
  # CREATE — visit get-or-create over BEHOENCX FETCH with the CREATE flag
  # (FETCH^BEHOENCX; GETVISIT is a pure fetch and never creates — rpms-ops
  # docs/REGISTRATION_RPC_CONTRACTS.md §3).
  # ===========================================================================

  def test_create_returns_visit_context_and_sends_fetch_params
    RpmsRpc.client.seed(:encounter_get_or_create, "26664", {
      location_name: "PS CLINICS", location_abbrev: "PSCL", provider_ien: 101,
      provider_name: "PROVIDER,TEST", visit_ien: 2090070, visit_id: "5000.1", locked: 0
    })

    result = RpmsRpc::Encounter.create(26664,
      location_ien: 1608, datetime: "3260904.0900", service_category: "A")

    assert result[:success]
    assert_equal 2090070, result[:visit_ien]
    assert_equal "PS CLINICS", result[:location_name]

    call = RpmsRpc.client.received_calls.last
    assert_equal "BEHOENCX FETCH", call[:rpc]
    # DFN, VSTR "LOC;FM_DATETIME;SVC_CAT", PRV, CREATE=1 (if-not-found)
    assert_equal [ "26664", "1608;3260904.0900;A", "", "1" ], call[:params]
  end

  def test_create_formats_datetime_and_passes_provider_and_create_flag
    RpmsRpc.client.seed(:encounter_get_or_create, "26664", { visit_ien: 2090071 })

    RpmsRpc::Encounter.create(26664,
      location_ien: 1608, datetime: Time.new(2026, 9, 4, 9, 0),
      service_category: "A", provider_ien: 101, create: -1)

    call = RpmsRpc.client.received_calls.last
    assert_equal [ "26664", "1608;3260904.0900;A", "101", "-1" ], call[:params]
  end

  def test_create_surfaces_server_error_text
    RpmsRpc.client.seed(:encounter_get_or_create, "26664", { error: "Visit not created" })

    result = RpmsRpc::Encounter.create(26664,
      location_ien: 1608, datetime: "3260904.0900", service_category: "A")

    refute result[:success]
    assert_equal "Visit not created", result[:error]
  end

  def test_create_returns_nil_when_broker_gives_no_response
    assert_nil RpmsRpc::Encounter.create(31337,
      location_ien: 1608, datetime: "3260904.0900", service_category: "A")
  end
end
