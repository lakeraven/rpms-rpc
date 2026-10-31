# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mappings"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/scheduling"

# Tests for RpmsRpc::Scheduling — the BSDX scheduling surface consumed by the
# lakeraven-ehr reg/sched twin (lakeraven-ehr#412). The broker is mocked — but
# NOT because dispatch is blocked. rpms-ops#366 (YDB releases lacking the #8994
# registry) closed 2026-08-23; ^XWB is force-included in the export and its
# absence now fails the build. What is still missing is a live-dispatch proof
# for this RPC set (rpms-rpc#224). See RpmsRpc::Scheduling's module comment.
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

  # SEARCH^BSDX24 params (BSDX24.m): RESOURCE_NAMES^START^END^ACCESS_TYPES^AMPM^WEEKDAYS.
  # Optional filters are sent as empty strings when omitted.
  def test_availability_sends_the_full_parameter_list
    avail_empty = availability_header_only_reply
    client = RpmsRpc.client
    client.seed_raw_lines(:scheduling_availability, "PEDIATRICIAN,DEMO|FUNAKOSHI,GICHIN", avail_empty)
    client.seed_raw_lines(:scheduling_availability, "PEDIATRICIAN,DEMO", avail_empty)

    start_d = Date.new(2026, 8, 12)
    end_d = Date.new(2026, 8, 19)
    RpmsRpc::Scheduling.availability(
      resources: [ "PEDIATRICIAN,DEMO", "FUNAKOSHI,GICHIN" ],
      start_date: start_d, end_date: end_d,
      access_types: "ROUTINE|URGENT", ampm: "AM", weekdays: "1|2|3"
    )

    assert_equal [
      "PEDIATRICIAN,DEMO|FUNAKOSHI,GICHIN",
      RpmsRpc::FilemanDateParser.to_fileman(start_d),
      RpmsRpc::FilemanDateParser.to_fileman(end_d),
      "ROUTINE|URGENT", "AM", "1|2|3"
    ], RpmsRpc.client.received_calls.last[:params]

    RpmsRpc.client.received_calls.clear
    RpmsRpc::Scheduling.availability(
      resources: "PEDIATRICIAN,DEMO",
      start_date: start_d, end_date: end_d
    )

    assert_equal [
      "PEDIATRICIAN,DEMO",
      RpmsRpc::FilemanDateParser.to_fileman(start_d),
      RpmsRpc::FilemanDateParser.to_fileman(end_d),
      "", "", ""
    ], RpmsRpc.client.received_calls.last[:params]
  end

  def test_availability_empty_reply_returns_no_blocks
    stub_broker_response([
      "T00030RESOURCENAME^D00030DATE^T00030ACCESSTYPE^T00030COMMENT\u001E",
      ""
    ])

    blocks = RpmsRpc::Scheduling.availability(
      resources: "PEDIATRICIAN,DEMO",
      start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 30)
    )

    assert_equal [], blocks
  end

  def test_availability_raises_when_the_broker_answers_with_an_error
    erroring = Class.new do
      def call_rpc(*) = raise(RpmsRpc::Client::RpcError, "BSDX SEARCH AVAILABILITY: error 4")
    end.new
    RpmsRpc.configure { |cfg| cfg.client = erroring }

    assert_raises(RpmsRpc::Client::RpcError) do
      RpmsRpc::Scheduling.availability(
        resources: "PEDIATRICIAN,DEMO",
        start_date: Date.new(2026, 8, 12), end_date: Date.new(2026, 8, 19)
      )
    end
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

  # CLNSET^BSDX32 header (BSDX32.m / mapping comment): I HOSPITAL_LOCATION_ID ^
  # T HOSPITAL_LOCATION ^ T CREATE_VISIT ^ T VISIT_SERVICE_CATEGORY ^
  # T MULTIPLE_CLINIC_CODES_USED? ^ T VISIT_PROVIDER_REQUIRED ^
  # T GENERATE_PCCPLUS_FORMS? ^ T MAX_OVERBOOKS. Params: (none).
  CLINIC_SETUP_HEADER =
    "I00010HOSPITAL_LOCATION_ID^T00030HOSPITAL_LOCATION^T00030CREATE_VISIT^" \
    "T00030VISIT_SERVICE_CATEGORY^T00030MULTIPLE_CLINIC_CODES_USED?^" \
    "T00030VISIT_PROVIDER_REQUIRED^T00030GENERATE_PCCPLUS_FORMS?^T00010MAX_OVERBOOKS\u001E"

  def test_clinic_setup_parses_wire_recordset_regression
    stub_broker_response([
      CLINIC_SETUP_HEADER,
      "44^PEDIATRIC CLINIC^YES^A^NO^YES^NO^2\u001E",
      ""
    ])

    setup = RpmsRpc::Scheduling.clinic_setup

    assert_equal 1, setup.size
    row = setup.first
    assert_equal 44, row[:location_ien]
    assert_equal "PEDIATRIC CLINIC", row[:location]
    assert_equal "YES", row[:create_visit]
    assert_equal "A", row[:visit_service_category]
    assert_equal "NO", row[:multiple_clinic_codes]
    assert_equal "YES", row[:visit_provider_required]
    assert_equal "NO", row[:generate_pccplus_forms]
    assert_equal 2, row[:max_overbooks]
  end

  def test_clinic_setup_empty_reply_returns_no_rows
    stub_broker_response([ CLINIC_SETUP_HEADER, "" ])

    assert_equal [], RpmsRpc::Scheduling.clinic_setup
  end

  def test_clinic_setup_raises_when_the_broker_answers_with_an_error
    erroring = Class.new do
      def call_rpc(*) = raise(RpmsRpc::Client::RpcError, "BSDX CLINIC SETUP: error 4")
    end.new
    RpmsRpc.configure { |cfg| cfg.client = erroring }

    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Scheduling.clinic_setup }
  end

  # -- BSDXRPC / CIAV VUECENTRIC context binding (rpms-rpc#258, #418) ---------
  #
  # RPC registration is OPTION-scoped (RpmsRpc::ContextScope). On a built 9.0
  # image BSDX RPCs sit in BSDXRPC; DDR GETS ENTRY DATA (used by undo_checkin)
  # sits in CIAV VUECENTRIC. Each method binds the option that registers the
  # RPC it is about to call and hands the caller's option back afterward.

  # Arguments that let every public method reach the wire. Writes stay unseeded
  # ("" is fine for fetch_one); list reads are seeded header-only so #481 does
  # not raise before the context assertions run.
  AVAILABILITY_LIST_HEADER =
    "T00030RESOURCENAME^D00030DATE^T00030ACCESSTYPE^T00030COMMENT"
  ALL_APPOINTMENTS_LIST_HEADER =
    "D00030START_TIME^D00030END_TIME^I00010PAT_ID^T00030RES_NAME"
  HOSPITAL_LOCATION_LIST_HEADER =
    "I00010HOSPITAL_LOCATION_ID^T00030HOSPITAL_LOCATION^T00030DEFAULT_PROVIDER^" \
    "T00030STOP_CODE_NUMBER^D00030INACTIVATE_DATE^D00030REACTIVATE_DATE"
  RESOURCES_RECORDSET_HEADER =
    "I00010RESOURCEID^T00030RESOURCE_NAME^T00010INACTIVE^I00010TIMESCALE^I00010HOSPITAL_LOCATION_ID^" \
    "T00030LETTER_TEXT^T00030NO_SHOW_LETTER^T00030CLINIC_CANCELLATION_LETTER^I00010VIEW^I00010OVERBOOK^" \
    "I00010MODIFY_SCHEDULE^I00010MODIFY_APPOINTMENTS"
  SLOTS_RECORDSET_HEADER =
    "D00030START_TIME^D00030END_TIME^I00010SLOTS^T00030RESOURCE^T00010ACCESS_TYPE^T00250NOTE^I00030AVAILABILITYID"
  APPTS_RECORDSET_HEADER =
    "I00020APPOINTMENTID^D00030START_TIME^D00030END_TIME^D00030CHECKIN^D00030AUXTIME^I00020PATIENTID^" \
    "T00030PATIENTNAME^T00030RESOURCENAME^I00005NOSHOW^T00020HRN^I00005ACCESSTYPEID^I00005WALKIN^" \
    "D00030CHECKOUT^I00020VPROVIDER^T00020CANCELLED^T00250NOTE"

  def availability_header_only_reply
    [ "#{AVAILABILITY_LIST_HEADER}\x1e", "" ]
  end

  def bsdx_fetch_many_header_only_lines(header)
    bare = header.delete_suffix("\x1e")
    [ "#{bare}\x1e", "" ]
  end

  # PADISP^BSDX27's header, as a live 7c3119b build answered it.
  PATIENT_APPTS_RECORDSET_HEADER = "T00030Name^D00020DOB^T00030Sex^T00030HRN^D00030ApptDate^T00030Clinic^T00030TypeStatus^" \
                                   "I00010RESOURCEID^T00030APPT_MADE_BY^D00020DATE_APPT_MADE^T00250NOTE^T00030STREET^T00030CITY^" \
                                   "T00030STATE^T00030ZIP^T00030HOMEPHONE"

  def bsdx_recordset_header_only_wire(header)
    "1\x00#{header.delete_suffix("\x1e")}\x1e\x1f"
  end

  def seed_mock_global_array!(mock, rpc, key, header)
    wire = bsdx_recordset_header_only_wire(header)
    tables = mock.instance_variable_get(:@lines) || {}
    tables[rpc] ||= {}
    tables[rpc][key.to_s] = wire
    mock.instance_variable_set(:@lines, tables)
  end

  def seed_empty_bsdx_list_reads!(mock, resource: "PEDIATRICIAN,DEMO")
    mock.seed_raw_lines(:scheduling_availability, resource,
                        bsdx_fetch_many_header_only_lines(AVAILABILITY_LIST_HEADER))
    mock.seed_raw_lines(:scheduling_all_appointments, START_FM,
                        bsdx_fetch_many_header_only_lines(ALL_APPOINTMENTS_LIST_HEADER))
    mock.seed_raw_lines(:scheduling_hospital_location, "",
                        bsdx_fetch_many_header_only_lines(HOSPITAL_LOCATION_LIST_HEADER))
    mock.seed_raw_lines(:scheduling_clinic_setup, "",
                        bsdx_fetch_many_header_only_lines(CLINIC_SETUP_HEADER))
    seed_mock_global_array!(mock, "BSDX RESOURCES", "", RESOURCES_RECORDSET_HEADER)
    seed_mock_global_array!(mock, "BSDX CREATE ASGND SLOT SCHED", resource, SLOTS_RECORDSET_HEADER)
    seed_mock_global_array!(mock, "BSDX CREATE APPT SCHEDULE", resource, APPTS_RECORDSET_HEADER)
    seed_mock_global_array!(mock, "BSDX PATIENT APPT DISPLAY", "100", PATIENT_APPTS_RECORDSET_HEADER)
  end

  UNDO_CHECKIN_RESOURCE_IEN = 88
  UNDO_CHECKIN_HOSPITAL_LOC = 1608

  def seed_ddr_gets!(mock, file:, iens:, fields:, text:)
    key = RpmsRpc::DdrFileman.gets_entry_param(file: file, iens: iens, fields: fields, flags: "I").to_s
    mock.seed(:ddr_gets_entry_data, key, text)
  end

  # undo_checkin preflight: #9002018.4 .03 set, .07 a resource; resource .04 set.
  def seed_undo_checkin_bsdx_path!(mock, appt_ien: 501, resource: UNDO_CHECKIN_RESOURCE_IEN,
                                   hospital: UNDO_CHECKIN_HOSPITAL_LOC)
    seed_ddr_gets!(mock, file: "9002018.4", iens: "#{appt_ien},", fields: ".03;.07", text: <<~REPLY.strip)
      [Data]
      9002018.4^#{appt_ien}^.03^#{START_FM}^
      9002018.4^#{appt_ien}^.07^#{resource}^
    REPLY
    seed_ddr_gets!(mock, file: "9002018.1", iens: "#{resource},", fields: ".04", text: <<~REPLY.strip)
      [Data]
      9002018.1^#{resource}^.04^#{hospital}^
    REPLY
    mock.seed(:scheduling_checkin_appointment, appt_ien.to_s, { error: "0" })
    seed_ddr_gets!(mock, file: "9002018.4", iens: "#{appt_ien},", fields: ".03", text: <<~REPLY.strip)
      [Data]
      9002018.4^#{appt_ien}^.03^#
    REPLY
  end

  BSDX_CALLS = {
    add_appointment: [ { patient_dfn: 100, resource: "PEDIATRICIAN,DEMO", start_time: START_T,
                         end_time: END_T, length_minutes: 30 } ],
    cancel_appointment: [ 501, { reason: 3 } ],
    uncancel_appointment: [ 501 ],
    checkin_appointment: [ 501, { checkin_time: START_T } ],
    undo_checkin: [ 501 ],
    mark_no_show: [ 501 ],
    patient_appointments: [ 100 ],
    availability: [ { resources: "PEDIATRICIAN,DEMO", start_date: START_T, end_date: END_T } ],
    all_appointments: [ { start_date: START_T, end_date: END_T } ],
    hospital_locations: [],
    clinic_setup: [],
    resources: [],
    appointments: [ { resource: "PEDIATRICIAN,DEMO", start_date: START_T, end_date: END_T } ],
    slot_schedule: [ { resource: "PEDIATRICIAN,DEMO", start_date: START_T, end_date: END_T } ]
  }.freeze

  def test_the_bind_table_names_every_public_method
    expected = RpmsRpc::Scheduling.public_instance_methods(false).sort

    assert_equal expected, BSDX_CALLS.keys.sort,
      "a new Scheduling method must be added to BSDX_CALLS so its context bind is proven"
  end

  def test_every_bsdx_call_runs_under_bsdxrpc_and_restores_the_callers_context
    BSDX_CALLS.each do |method, args|
      mock = RpmsRpc.mock!
      seed_empty_bsdx_list_reads!(mock)
      seed_undo_checkin_bsdx_path!(mock) if method == :undo_checkin
      caller_context = mock.current_context
      positional = args.reject { |a| a.is_a?(Hash) }
      keywords = args.find { |a| a.is_a?(Hash) } || {}

      RpmsRpc::Scheduling.public_send(method, *positional, **keywords)

      calls = mock.received_calls
      refute_empty calls, "#{method} made no RPC call"
      bsdx_calls = calls.select { |c| c[:rpc].start_with?("BSDX") }
      refute_empty bsdx_calls, "#{method} made no BSDX RPC call"
      calls.each do |call|
        rpc = call[:rpc]
        if rpc.start_with?("BSDX")
          assert_equal "BSDXRPC", call[:context],
            "#{method} sent #{rpc} under #{call[:context].inspect}; BSDX RPCs " \
            "are registered under BSDXRPC"
        elsif rpc.start_with?("DDR ")
          assert_equal "CIAV VUECENTRIC", call[:context],
            "#{method} sent #{rpc} under #{call[:context].inspect}; DDR RPCs " \
            "are registered under CIAV VUECENTRIC, not BSDXRPC"
        else
          flunk "#{method} sent unexpected RPC #{rpc.inspect} under #{call[:context].inspect}"
        end
      end
      assert_equal caller_context, mock.current_context,
        "#{method} left the session on #{mock.current_context.inspect}"
    end
  end

  def test_a_bsdxrpc_that_will_not_bind_raises_before_any_rpc_is_sent
    mock = RpmsRpc.mock!
    mock.unbindable_context!("BSDXRPC")

    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Scheduling.hospital_locations }
    assert_empty mock.received_calls
  end

  def test_a_client_that_cannot_scope_contexts_runs_as_is
    # RawResponseClient has no with_context; the scope is skipped, not refused.
    stub_broker_response([ "T00020BMXIEN^T00030HOSPITAL_LOCATION", "44^PEDIATRIC CLINIC" ])

    clinics = RpmsRpc::Scheduling.hospital_locations

    assert_equal 1, clinics.length
  end
end
