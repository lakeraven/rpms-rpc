# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/encounter"

class EncounterTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      # Existing read API
      m.seed_keyed_collection(:patient_appointments, "26664", [
        { datetime: nil, location_ien: 1608, location: "PS CLINICS", status: "scheduled" }
      ])

      # Open: BEHOENCX GETVISIT — visit_ien -> LOC^VDT^SVC^PAT^VID^LOCKED
      # (GETVISIT^BEHOENCX: BEHOENCX.m:5,8-15)
      m.seed(:encounter_visit, "2090061", {
        location_ien: 1608,
        datetime_raw: "3260514.1907",
        service_category: "A",
        patient_dfn: 26664,
        visit_id: "5000.61",
        locked: false
      })

      # Open: BEHOENCX FETCH(DFN,VSTR,PRV,CREATE) — keyed by its FIRST param,
      # the DFN. LOCNAME^LOCABBR^ROOMBED^PROVIEN^PROVNAME^VISITIEN^VISITID^
      # LOCKED^ERRORTXT (FETCH^BEHOENCX: BEHOENCX.m:30-31)
      m.seed(:encounter_fetch, "26664", {
        location_name:   "PS CLINICS",
        location_abbrev: "PSCL",
        room_bed:        "",
        provider_ien:    101,
        provider_name:   "SAND,ASH",
        visit_ien:       2090061,
        visit_id:        "5000.61",
        locked:          false
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
    # Consumer keys, each from the piece that really carries it:
    assert_equal 1608,    result[:location_ien]        # GETVISIT piece 1 (FETCH has no location IEN)
    assert_equal "PS CLINICS", result[:location]       # FETCH piece 1 LOCNAME
    assert_equal "PSCL",       result[:clinic_abbrev]  # FETCH piece 2 LOCABBR
    assert_equal "SAND,ASH",   result[:provider]       # FETCH piece 5 PROVNAME
    assert_equal 101,          result[:provider_ien]   # FETCH piece 4 PROVIEN
    assert_equal "3260514.1907", result[:datetime_raw] # GETVISIT piece 2 VDT
    assert_equal "A", result[:service_category]        # GETVISIT piece 3 SVC
    assert_equal "A", result[:status]                  # same piece, the name consumers already read
    assert_equal "5000.61", result[:visit_id]          # GETVISIT piece 5 / FETCH piece 7
    assert_equal false, result[:locked]                # GETVISIT piece 6 / FETCH piece 8
    refute result.key?(:ward), "no BEHOENCX reply carries a ward; the key was invented"
  end

  # FETCH's real signature is FETCH(DATA,DFN,VSTR,PRV,CREATE) (BEHOENCX.m:32).
  # open() sends the DFN and the EXTENDED visit string built from GETVISIT —
  # LOC;VDT;SVC;VISITIEN — so VSTR2VIS resolves the visit by IEN
  # (BEHOENCX.m:107) and CREATE=0 never adds one. Sending the visit IEN alone
  # put it in DFN and left VSTR undefined (<UNDEF> at VSTR2VIS+2).
  def test_open_sends_fetch_the_dfn_and_the_extended_visit_string_with_create_0
    RpmsRpc::Encounter.open(26664, 2090061)

    fetch = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BEHOENCX FETCH" }
    refute_nil fetch
    assert_equal [ "26664", "1608;3260514.1907;A;2090061", "", "0" ], fetch[:params]

    getvisit = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BEHOENCX GETVISIT" }
    assert_equal [ "2090061" ], getvisit[:params]
  end

  # FETCH reports a visit it could not resolve by leaving VISITIEN empty and
  # putting the text in piece 9 (BEHOENCX.m:46) — e.g. "-1^Visit does not
  # belong to current patient" from VIS2VSTR (BEHOENCX.m:118). That is not a
  # hydrated context.
  def test_open_returns_nil_when_fetch_reports_an_error_instead_of_a_visit
    RpmsRpc.client.seed(:encounter_fetch, "26664", {
      location_name: "PS CLINICS", location_abbrev: "PSCL", provider_ien: 101,
      provider_name: "SAND,ASH", error: "Visit does not belong to current patient"
    })

    assert_nil RpmsRpc::Encounter.open(26664, 2090061)
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
        location_ien: 1608, datetime_raw: "3260514.1907", service_category: "A",
        patient_dfn: 26664, visit_id: "5000.61", locked: false
      })
      # Intentionally no :encounter_fetch seed
      m.seed_keyed_collection(:encounter_chkvisit, "2090061", [])
    end
    assert_nil RpmsRpc::Encounter.open(26664, 2090061)
  end

  # visit_string accepts a Date as documented: a plain Date has no clock, so it
  # is a FileMan date. It used to raise NoMethodError (Date#hour is private),
  # found by a live read-API run against yotta-0921 (2026-09-23).
  def test_visit_string_formats_a_plain_date_as_a_fileman_date
    assert_equal "1;3260923;A", RpmsRpc::Encounter.visit_string(1, Date.new(2026, 9, 23), "A")
  end

  def test_visit_string_keeps_the_clock_of_a_time_or_datetime
    assert_equal "1;3260923.1430;A", RpmsRpc::Encounter.visit_string(1, Time.new(2026, 9, 23, 14, 30), "A")
    assert_equal "1;3260923.1430;A", RpmsRpc::Encounter.visit_string(1, DateTime.new(2026, 9, 23, 14, 30), "A")
  end

  def test_visit_string_passes_a_preformatted_fileman_string_through
    assert_equal "6;3260915.003;A", RpmsRpc::Encounter.visit_string(6, "3260915.003", "A")
  end

  # The EXTENDED visit string carries the visit IEN as a 4th piece; VSTR2VIS
  # reads it (BEHOENCX.m:107 "IEN=+$P(VSTR,\";\",4)") and skips the FNDVIS
  # date-window search when it is set.
  def test_visit_string_appends_the_visit_ien_when_given
    assert_equal "6;3260915.003;A;1", RpmsRpc::Encounter.visit_string(6, "3260915.003", "A", visit_ien: 1)
    assert_equal "6;3260915.003;A", RpmsRpc::Encounter.visit_string(6, "3260915.003", "A", visit_ien: nil)
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
    RpmsRpc.client.seed(:encounter_fetch, "26664", {
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
    RpmsRpc.client.seed(:encounter_fetch, "26664", { visit_ien: 2090071 })

    RpmsRpc::Encounter.create(26664,
      location_ien: 1608, datetime: Time.new(2026, 9, 4, 9, 0),
      service_category: "A", provider_ien: 101, create: -1)

    call = RpmsRpc.client.received_calls.last
    assert_equal [ "26664", "1608;3260904.0900;A", "101", "-1" ], call[:params]
  end

  def test_create_surfaces_server_error_text
    RpmsRpc.client.seed(:encounter_fetch, "26664", { error: "Visit not created" })

    result = RpmsRpc::Encounter.create(26664,
      location_ien: 1608, datetime: "3260904.0900", service_category: "A")

    refute result[:success]
    assert_equal "Visit not created", result[:error]
  end

  def test_create_returns_nil_when_broker_gives_no_response
    assert_nil RpmsRpc::Encounter.create(31337,
      location_ien: 1608, datetime: "3260904.0900", service_category: "A")
  end

  # === visit_string(location_ien, datetime, service_category) ===

  def test_visit_string_formats_a_date_without_a_time
    assert_equal "1608;3260924;A", RpmsRpc::Encounter.visit_string(1608, Date.new(2026, 9, 24), "A")
  end

  def test_visit_string_formats_a_time_to_the_minute
    assert_equal "1608;3260924.0930;A", RpmsRpc::Encounter.visit_string(1608, Time.new(2026, 9, 24, 9, 30, 15), "A")
  end

  def test_visit_string_formats_a_datetime_to_the_minute
    assert_equal "1608;3260924.1405;A",
                 RpmsRpc::Encounter.visit_string(1608, DateTime.new(2026, 9, 24, 14, 5, 0), "A")
  end

  def test_visit_string_passes_a_fileman_string_through
    assert_equal "1608;3260924.09;A", RpmsRpc::Encounter.visit_string(1608, "3260924.09", "A")
  end
end
