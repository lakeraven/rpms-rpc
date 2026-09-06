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

  # Broker stub returning one canned raw reply for every RPC — for live-wire
  # shapes MockClient can't produce (typed recordset header rows, $C(30)/$C(31)
  # separators, external-format dates).
  class RawResponseClient
    def initialize(response) = @response = response
    def supports?(*) = true
    def call_rpc(*) = @response
  end

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def stub_broker_response(response)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = RawResponseClient.new(response) }
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

  # Regression: DateTime < Date in Ruby, so a `when Date` branch listed before
  # `when Time` swallowed DateTime inputs and formatted them date-only —
  # silently booking appointments with no time of day.
  def test_add_appointment_datetime_keeps_time_of_day_regression
    RpmsRpc.client.seed(:scheduling_add_appointment, START_FM,
                        { appointment_id: 501, error: "" })

    RpmsRpc::Scheduling.add_appointment(
      patient_dfn: 100, resource: "PEDIATRICIAN,DEMO",
      start_time: DateTime.new(2026, 8, 12, 9, 0, 0),
      end_time: DateTime.new(2026, 8, 12, 9, 30, 0), length_minutes: 30
    )

    call = RpmsRpc.client.received_calls.last
    assert_equal START_FM, call[:params][0],
                 "DateTime start must format as FileMan date.time, not date-only"
    assert_equal END_FM, call[:params][1]
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

  # Regression: on live dispatch a BMX recordset reply opens with the typed
  # column-header row (APPADD^BSDX07 writes "I00020APPOINTMENTID^T00020ERRORID")
  # and rows carry $C(30) separators / a closing $C(31). The header row was
  # stripped only on the error_write path, so fetch_one parsed it as the data
  # row and a SUCCESSFUL booking reported failure.
  def test_add_appointment_live_recordset_header_is_not_data_regression
    stub_broker_response([
      "I00020APPOINTMENTID^T00020ERRORID",
      "501^",
      ""
    ])

    result = RpmsRpc::Scheduling.add_appointment(
      patient_dfn: 100, resource: "PEDIATRICIAN,DEMO",
      start_time: START_T, end_time: END_T, length_minutes: 30
    )

    assert result[:success], "header row must not be read as the data row"
    assert_equal 501, result[:appointment_id]
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
  end

  # Regression: only 4 of CHECKIN^BSDX25's client formals were sent. The
  # routine passes BSDXVCL/BSDXVFM/BSDXOG to APCHK by value with no $G
  # (BSDX25.m:63), so when the resource links a hospital location a 4-param
  # call dies server-side with <UNDEF>. All 8 formals (BSDX25.m:12 —
  # APTID^CDT^CC^PRV^ROU^VCL^VFM^OG) are now sent, trailing ones empty.
  def test_checkin_appointment_sends_all_eight_formals_regression
    RpmsRpc.client.seed(:scheduling_checkin_appointment, "501", { error: "0" })

    RpmsRpc::Scheduling.checkin_appointment(501, checkin_time: START_T,
                                            clinic_code: "301", provider: "PROVIDER,A")

    assert_equal [ "501", START_FM, "301", "PROVIDER,A", "", "", "", "" ],
                 RpmsRpc.client.received_calls.last[:params],
                 "BSDXROU/BSDXVCL/BSDXVFM/BSDXOG must be sent (empty) to avoid <UNDEF>"
  end

  # Regression: the LIVE success row is "0^"_EMSG (BSDX25.m:74) — two pieces,
  # ERRORID "0" plus an often-empty MESSAGE — but success was matched against
  # the whole row ("0" exactly / empty), so every live check-in reported
  # failure with error "0^".
  def test_checkin_appointment_live_success_row_zero_caret_regression
    stub_broker_response([
      "T00020ERRORID^T00150MESSAGE",
      "0^",
      ""
    ])

    result = RpmsRpc::Scheduling.checkin_appointment(501, checkin_time: START_T)

    assert result[:success], "\"0^\" ERRORID row is a successful check-in"
  end

  # A live failure row is the single-piece error text ERR^BSDX25 writes
  # (BSDX25.m:361-365).
  def test_checkin_appointment_live_failure_row
    stub_broker_response([
      "T00020ERRORID^T00150MESSAGE",
      "Invalid Appointment ID",
      ""
    ])

    result = RpmsRpc::Scheduling.checkin_appointment(999, checkin_time: START_T)

    refute result[:success]
    assert_match(/Invalid Appointment ID/, result[:error])
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

  # Regression: SEARCH^BSDX24 declares a D-typed DATE column but emits
  # EXTERNAL-format dates — it runs the internal date through DD^%DT before
  # writing the row (BSDX24.m:116-117), so the wire carries "SEP 04, 2026".
  # Typed :fileman_date, every availability date parsed nil. The row also ends
  # after ACCESSTYPE with a bare trailing "^" (BSDX24.m:124): COMMENT is
  # declared in the header but never populated.
  def test_availability_parses_external_format_dates_regression
    stub_broker_response([
      "T00030RESOURCENAME^D00030DATE^T00030ACCESSTYPE^T00030COMMENT\u001E",
      "PEDIATRICIAN,DEMO^SEP 04, 2026^ROUTINE^\u001E",
      ""
    ])

    blocks = RpmsRpc::Scheduling.availability(
      resources: "PEDIATRICIAN,DEMO",
      start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 30)
    )

    assert_equal 1, blocks.size
    block = blocks.first
    assert_equal "PEDIATRICIAN,DEMO", block[:resource_name]
    assert_equal Date.new(2026, 9, 4), block[:date],
                 "DATE column is external format (DD^%DT), not FileMan internal"
    assert_equal "ROUTINE", block[:access_type]
    assert_nil block[:comment]
  end

  # Regression: APBLKALL^BSDX05 emits EXTERNAL-format datetimes — STCOMM runs
  # X ^DD("DD") and translates the "@" to a space (BSDX05.m:100-101) — and a
  # 4th RES_NAME column appended per-row by GATHER (BSDX05.m:65,76). The
  # mapping typed the datetimes :fileman_datetime (parsed nil) and dropped
  # RES_NAME entirely.
  def test_all_appointments_parses_external_datetimes_and_resource_regression
    stub_broker_response([
      "D00030START_TIME^D00030END_TIME^I00010PAT_ID^T00030RES_NAME\u001E",
      "SEP 04, 2026 09:00^SEP 04, 2026 09:30^100^PEDIATRICIAN,DEMO\u001E",
      ""
    ])

    rows = RpmsRpc::Scheduling.all_appointments(
      start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 30)
    )

    assert_equal 1, rows.size
    row = rows.first
    assert_equal Time.new(2026, 9, 4, 9, 0, 0), row[:start_time],
                 "START_TIME is external format (X ^DD(\"DD\") with @ -> space)"
    assert_equal Time.new(2026, 9, 4, 9, 30, 0), row[:end_time]
    assert_equal 100, row[:patient_dfn]
    assert_equal "PEDIATRICIAN,DEMO", row[:resource_name]
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
