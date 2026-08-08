# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mappings"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/scheduling"

# Tests for RpmsRpc::Scheduling — the BSDX scheduling surface consumed by the
# lakeraven-ehr reg/sched twin (lakeraven-ehr#412). The broker is mocked; live
# dispatch is blocked on rpms-ops#366 (YDB releases lack the #8994 registry).
class SchedulingTest < Minitest::Test
  START_T = Time.new(2026, 8, 12, 9, 0, 0)
  END_T   = Time.new(2026, 8, 12, 9, 30, 0)
  START_FM = RpmsRpc::FilemanDateParser.format_datetime(START_T) # "3260812.0900"
  END_FM   = RpmsRpc::FilemanDateParser.format_datetime(END_T)

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # ===========================================================================
  # ADD (book)
  # ===========================================================================

  def test_add_appointment_success_returns_id
    RpmsRpc.client.seed(:scheduling_add_appointment, START_FM,
                        { appointment_id: 501, error: "" })

    result = RpmsRpc::Scheduling.add_appointment(
      patient_dfn: 100, resource: "PEDIATRICIAN,DEMO",
      start_time: START_T, end_time: END_T, length_minutes: 30, note: "well child"
    )

    assert result[:success]
    assert_equal 501, result[:appointment_id]
  end

  def test_add_appointment_sends_bsdx_add_new_appointment_with_param_order
    RpmsRpc.client.seed(:scheduling_add_appointment, START_FM,
                        { appointment_id: 501, error: "" })

    RpmsRpc::Scheduling.add_appointment(
      patient_dfn: 100, resource: "PEDIATRICIAN,DEMO",
      start_time: START_T, end_time: END_T, length_minutes: 30,
      note: "well child", access_type: "WALKIN", chart_request: true
    )

    call = RpmsRpc.client.received_calls.last
    assert_equal "BSDX ADD NEW APPOINTMENT", call[:rpc]
    # START^END^DFN^RESOURCE^LENGTH^NOTE^ACCESS_TYPE^CHART_REQUEST
    assert_equal [ START_FM, END_FM, "100", "PEDIATRICIAN,DEMO",
                   "30", "well child", "WALKIN", "1" ], call[:params]
  end

  def test_add_appointment_failure_returns_error
    RpmsRpc.client.seed(:scheduling_add_appointment, START_FM,
                        { appointment_id: 0, error: "BSDX07 Error: Invalid Resource ID" })

    result = RpmsRpc::Scheduling.add_appointment(
      patient_dfn: 100, resource: "NOPE", start_time: START_T, end_time: END_T,
      length_minutes: 30
    )

    refute result[:success]
    assert_match(/Invalid Resource ID/, result[:error])
  end

  def test_add_appointment_returns_nil_when_unreachable
    assert_nil RpmsRpc::Scheduling.add_appointment(
      patient_dfn: 100, resource: "X", start_time: START_T, end_time: END_T,
      length_minutes: 30
    )
  end

  # ===========================================================================
  # CANCEL / UNCANCEL (empty ERRORID == success)
  # ===========================================================================

  def test_cancel_appointment_success
    RpmsRpc.client.seed(:scheduling_cancel_appointment, "501", { error: "" })

    result = RpmsRpc::Scheduling.cancel_appointment(501, reason: 14, type: "PC", note: "moved")

    assert result[:success]
    call = RpmsRpc.client.received_calls.last
    assert_equal "BSDX CANCEL APPOINTMENT", call[:rpc]
    assert_equal [ "501", "PC", "14", "moved" ], call[:params]
  end

  def test_cancel_appointment_failure_passes_through_message
    RpmsRpc.client.seed(:scheduling_cancel_appointment, "501",
                        { error: "Patient already checked in; cannot cancel" })

    result = RpmsRpc::Scheduling.cancel_appointment(501, reason: 14)

    refute result[:success]
    assert_match(/already checked in/, result[:error])
  end

  def test_cancel_appointment_returns_nil_when_unreachable
    assert_nil RpmsRpc::Scheduling.cancel_appointment(501, reason: 14)
  end

  def test_uncancel_appointment_success
    RpmsRpc.client.seed(:scheduling_uncancel_appointment, "501", { error: "" })

    result = RpmsRpc::Scheduling.uncancel_appointment(501)

    assert result[:success]
    assert_equal "BSDX UNCANCEL APPT", RpmsRpc.client.received_calls.last[:rpc]
  end

  # ===========================================================================
  # CHECK-IN ("0"/empty == success)
  # ===========================================================================

  def test_checkin_appointment_success_on_zero
    RpmsRpc.client.seed(:scheduling_checkin_appointment, "501", { error: "0" })

    result = RpmsRpc::Scheduling.checkin_appointment(501, checkin_time: START_T,
                                                     clinic_code: "301", provider: "PROVIDER,A")

    assert result[:success]
    call = RpmsRpc.client.received_calls.last
    assert_equal "BSDX CHECKIN APPOINTMENT", call[:rpc]
    assert_equal [ "501", START_FM, "301", "PROVIDER,A" ], call[:params]
  end

  # Regression: an EMPTY ERRORID is a SUCCESSFUL check-in. fetch_one collapses
  # an empty data row to nil — the value reserved for "unreachable" — which
  # read a successful check-in as a broker failure (latent double-check-in).
  # Check-in now routes through the same direct-call helper as cancel/uncancel.
  def test_checkin_appointment_success_on_empty_errorid
    RpmsRpc.client.seed(:scheduling_checkin_appointment, "501", { error: "" })

    result = RpmsRpc::Scheduling.checkin_appointment(501, checkin_time: START_T)

    refute_nil result, "empty ERRORID must read as success, not unreachable"
    assert result[:success]
  end

  def test_checkin_appointment_failure
    RpmsRpc.client.seed(:scheduling_checkin_appointment, "501",
                        { error: "BSDX25: Invalid Appointment ID" })

    result = RpmsRpc::Scheduling.checkin_appointment(501, checkin_time: START_T)

    refute result[:success]
    assert_match(/Invalid Appointment ID/, result[:error])
  end

  def test_checkin_appointment_returns_nil_when_unreachable
    assert_nil RpmsRpc::Scheduling.checkin_appointment(501, checkin_time: START_T)
  end

  # ===========================================================================
  # NO-SHOW (INVERTED polarity: result 1 == success)
  # ===========================================================================

  def test_mark_no_show_success
    RpmsRpc.client.seed(:scheduling_noshow_appointment, "501", { result: 1, error: "" })

    result = RpmsRpc::Scheduling.mark_no_show(501)

    assert result[:success]
    call = RpmsRpc.client.received_calls.last
    assert_equal "BSDX NOSHOW", call[:rpc]
    assert_equal [ "501", "1" ], call[:params]
  end

  def test_clear_no_show_sends_zero_flag
    RpmsRpc.client.seed(:scheduling_noshow_appointment, "501", { result: 1, error: "" })

    RpmsRpc::Scheduling.mark_no_show(501, no_show: false)

    assert_equal [ "501", "0" ], RpmsRpc.client.received_calls.last[:params]
  end

  def test_mark_no_show_failure_result_zero
    RpmsRpc.client.seed(:scheduling_noshow_appointment, "501",
                        { result: 0, error: "BSDX31: Invalid No Show value" })

    result = RpmsRpc::Scheduling.mark_no_show(501)

    refute result[:success]
    assert_match(/Invalid No Show value/, result[:error])
  end

  # ===========================================================================
  # READS
  # ===========================================================================

  def test_availability_returns_blocks
    RpmsRpc.client.seed_collection(:scheduling_availability, [
      { resource_name: "PEDIATRICIAN,DEMO", date: Date.new(2026, 8, 12),
        access_type: "ROUTINE", comment: "" }
    ])

    blocks = RpmsRpc::Scheduling.availability(
      resources: [ "PEDIATRICIAN,DEMO", "FUNAKOSHI,GICHIN" ],
      start_date: Date.new(2026, 8, 12), end_date: Date.new(2026, 8, 19)
    )

    assert_equal 1, blocks.size
    assert_equal "PEDIATRICIAN,DEMO", blocks.first[:resource_name]
    assert_equal "ROUTINE", blocks.first[:access_type]
    # Resources joined with "|" into the first param.
    assert_equal "PEDIATRICIAN,DEMO|FUNAKOSHI,GICHIN",
                 RpmsRpc.client.received_calls.last[:params].first
  end

  def test_availability_rejects_pipe_in_resource_name
    err = assert_raises(ArgumentError) do
      RpmsRpc::Scheduling.availability(
        resources: [ "PEDIATRICIAN,DEMO|SMUGGLED,RES" ],
        start_date: Date.new(2026, 8, 12), end_date: Date.new(2026, 8, 19)
      )
    end
    assert_match(/must not contain '\|'/, err.message)
    assert_empty RpmsRpc.client.received_calls, "no RPC should be sent"
  end

  def test_all_appointments_returns_rows
    RpmsRpc.client.seed_collection(:scheduling_all_appointments, [
      { start_time: START_T, end_time: END_T, patient_dfn: 100 }
    ])

    rows = RpmsRpc::Scheduling.all_appointments(
      start_date: Date.new(2026, 8, 1), end_date: Date.new(2026, 8, 31)
    )

    assert_equal 1, rows.size
    assert_equal 100, rows.first[:patient_dfn]
  end

  def test_hospital_locations_returns_clinics
    RpmsRpc.client.seed_collection(:scheduling_hospital_location, [
      { location_ien: 44, location: "PEDIATRIC CLINIC", default_provider: "PROVIDER,A",
        stop_code: "323", inactivate_date: nil, reactivate_date: nil }
    ])

    clinics = RpmsRpc::Scheduling.hospital_locations

    assert_equal 44, clinics.first[:location_ien]
    assert_equal "PEDIATRIC CLINIC", clinics.first[:location]
  end

  def test_clinic_setup_returns_params
    RpmsRpc.client.seed_collection(:scheduling_clinic_setup, [
      { location_ien: 44, location: "PEDIATRIC CLINIC", create_visit: "YES",
        visit_service_category: "A", multiple_clinic_codes: "NO",
        visit_provider_required: "YES", generate_pccplus_forms: "NO", max_overbooks: 2 }
    ])

    setup = RpmsRpc::Scheduling.clinic_setup

    assert_equal 44, setup.first[:location_ien]
    assert_equal 2, setup.first[:max_overbooks]
  end
end
