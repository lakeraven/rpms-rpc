# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/scheduling"
require_relative "../stock_rpcs_test_helper"

# Supplemental BSDX stock-RPC tests for rpms-rpc#420 (methods not yet on Scheduling).
class SchedulingStockRpcsTest < Minitest::Test
  include StockRpcsTestHelper

  RS = "\x1e"
  US = "\x1f"
  START_T = Time.new(2026, 9, 4, 9, 0, 0)
  START_FM = "3260904.09"

  RESOURCES_BY_USER_HEADER =
    "I00010RESOURCEID^T00030RESOURCE_NAME^T00010INACTIVE^I00010TIMESCALE^I00010HOSPITAL_LOCATION_ID^" \
    "T00030LETTER_TEXT^T00030NO_SHOW_LETTER^T00030CLINIC_CANCELLATION_LETTER^I00010VIEW^I00010OVERBOOK^" \
    "I00010MODIFY_SCHEDULE^I00010MODIFY_APPOINTMENTS"

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # RESUSR^BSDX01 (BSDX01.m:100-112): same resource columns as BSDX RESOURCES.
  def test_resources_by_user_parses_resource_rows
    wire = recordset_wire(RESOURCES_BY_USER_HEADER, "7^DEMO CLINIC^0^15^44^^^^1^1^1^1")
    seed_global("BSDX RESOURCES BY USER", "101", wire)

    rows = RpmsRpc::Scheduling.resources_by_user(duz: 101)

    assert_equal 1, rows.size
    assert_equal 7, rows.first[:id]
    assert_equal "DEMO CLINIC", rows.first[:name]
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BSDX RESOURCES BY USER" }
    assert_equal [ "101" ], call[:params]
    assert_equal RpmsRpc::Scheduling::CONTEXT, call[:context]
  end

  def test_resources_by_user_defaults_duz_to_empty_string
    wire = recordset_wire(RESOURCES_BY_USER_HEADER, "")
    seed_global("BSDX RESOURCES BY USER", "", wire)

    RpmsRpc::Scheduling.resources_by_user

    assert_equal [ "" ], RpmsRpc.client.received_calls.last[:params]
  end

  def test_resources_by_user_is_read_in_retry_safety
    assert_equal :read, RpmsRpc::RetrySafety.for(RpmsRpc::Scheduling, :resources_by_user)
  end

  # Check-in visit: BEHOENCX GETVISIT (GETVISIT^BEHOENCX, BEHOENCX.m:8-15) returns
  # LOC^VDT^SVC^PAT^VID^LOCKED for a visit IEN — chosen over DDR LISTER on #9000010
  # because CHECKIN^BSDX25 already uses GETVISIT^BSDAPI4 for the same shape.
  def test_checkin_visit_reads_behoencx_getvisit_not_ddr_lister_on_9000010
    # GETVISIT^BEHOENCX: LOC^VDT^SVC^PAT^VID^LOCKED (BEHOENCX.m:8-15)
    RpmsRpc.client.seed(:encounter_visit, "44101", {
      location_ien: 44,
      datetime_raw: START_FM,
      service_category: "A",
      patient_dfn: 990_031,
      visit_id: "5000.101",
      locked: false
    })

    visit = RpmsRpc::Scheduling.checkin_visit(visit_ien: 44_101)

    assert_equal 44, visit[:location_ien]
    assert_equal "A", visit[:service_category]
    assert_equal 990_031, visit[:patient_dfn]
    refute visit[:locked]
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BEHOENCX GETVISIT" }
    refute_nil call, "expected BEHOENCX GETVISIT, not DDR LISTER on file 9000010"
    assert_equal [ "44101" ], call[:params]
    refute RpmsRpc.client.received_calls.any? { |c| c[:rpc] == "DDR LISTER" }
  end

  def test_checkin_visit_returns_nil_when_getvisit_data_is_empty
    # Unresolved visit IEN: GETVISIT leaves DATA empty (BEHOENCX.m:11-12).
    assert_nil RpmsRpc::Scheduling.checkin_visit(visit_ien: 99_999)
  end

  def test_checkin_visit_is_read_in_retry_safety
    assert_equal :read, RpmsRpc::RetrySafety.for(RpmsRpc::Scheduling, :checkin_visit)
  end

  READ_GET_ROUTES = File.join(__dir__, "../../fixtures/openapi/read_get_catalog_routes.tsv").freeze

  # BEHOENCX GETVISIT is a read; the OpenAPI catalog publishes it as GET (read_get_catalog_routes.tsv).
  def test_checkin_visit_openapi_catalog_route_is_get
    key = "RpmsRpc::Scheduling.checkin_visit"
    expected = File.readlines(READ_GET_ROUTES, chomp: true).reject(&:empty?).to_h do |line|
      route_key, route = line.split("\t", 2)
      [ route_key, route ]
    end.fetch(key)

    shape = RpmsRpc::Shape.for(RpmsRpc::Scheduling, :checkin_visit)
    refute_nil shape, "checkin_visit must declare an OpenAPI shape"
    verb, path = expected.split(" ", 2)
    assert_equal verb, shape[:verb]
    assert_equal path, shape[:path]
  end

  # CHECKIN^BSDX25 (BSDX25.m:24-25): non-numeric and unknown IEN → Invalid Appointment ID.
  def test_checkin_appointment_non_numeric_id_returns_invalid_appointment_id
    stub_checkin_reply("Invalid Appointment ID#{RS}")

    result = RpmsRpc::Scheduling.checkin_appointment("abc", checkin_time: START_T)

    refute result[:success]
    assert_match(/Invalid Appointment ID/, result[:error])
  end

  def test_checkin_appointment_unknown_numeric_id_returns_invalid_appointment_id
    stub_checkin_reply("BSDX08: Invalid Appointment ID#{RS}")

    result = RpmsRpc::Scheduling.checkin_appointment(999_999, checkin_time: START_T)

    refute result[:success]
    assert_match(/Invalid Appointment ID/, result[:error])
  end

  # BSDX SEARCH AVAILABILITY — thin encoding test (SEARCH^BSDX24) via Scheduling.availability.
  def test_search_availability_sends_resource_and_date_range
    RpmsRpc.client.seed_raw_lines(:scheduling_availability, "PEDIATRICIAN,DEMO",
                                  [ "T00030RESOURCENAME^D00030DATE^T00030ACCESSTYPE^T00030COMMENT#{RS}", "" ])

    RpmsRpc::Scheduling.availability(
      resources: "PEDIATRICIAN,DEMO",
      start_date: Date.new(2026, 9, 1),
      end_date: Date.new(2026, 9, 30)
    )

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BSDX SEARCH AVAILABILITY" }
    refute_nil call
    assert_equal RpmsRpc::Scheduling::CONTEXT, call[:context]
  end

  def test_clinic_setup_binds_bsdxrpc
    RpmsRpc.client.seed_raw_lines(:scheduling_clinic_setup, "",
                                  [ "I00010HOSPITAL_LOCATION_ID^T00030HOSPITAL_LOCATION#{RS}", "" ])

    RpmsRpc::Scheduling.clinic_setup

    assert_equal "BSDXRPC", RpmsRpc.client.received_calls.last[:context]
  end

  def test_checkout_appointment_invalid_reply_is_not_success
    RpmsRpc.client.seed(:scheduling_checkout_appointment, "100",
                        { error: "BSDX25B: Patient not checked in" })

    result = RpmsRpc::Scheduling.checkout_appointment(
      501, patient_dfn: 100, appointment_time: START_T, checkout_time: START_T + 3600
    )

    refute result[:success]
    assert_match(/not checked in/, result[:error])
  end

  def test_cancel_checkout_refuses_when_not_checked_out
    RpmsRpc.client.seed(:scheduling_cancel_checkout, "501",
                        { error: "Appointment is not Checked Out." })

    result = RpmsRpc::Scheduling.cancel_checkout(501)

    refute result[:success]
    assert_match(/not Checked Out/, result[:error])
  end

  def test_required_rpcs_lists_bsdx_stock_rpcs_under_scheduling
    assert_required_rpc(
      "BSDX SEARCH AVAILABILITY",
      "BSDX CLINIC SETUP",
      "BSDX CHECKIN APPOINTMENT",
      "BSDX CHECKOUT APPOINTMENT",
      "BSDX CANCEL CHECKOUT APPT",
      "BSDX RESOURCES",
      "BSDX RESOURCES BY USER",
      under: "RpmsRpc::Scheduling"
    )
    assert_includes required_rpc_names, "BEHOENCX GETVISIT"
  end

  private

  def recordset_wire(header, row)
    "1\x00#{header}#{RS}#{row}#{RS}#{US}"
  end

  def seed_global(rpc, key, wire)
    mock = RpmsRpc.client
    tables = mock.instance_variable_get(:@lines) || {}
    tables[rpc] ||= {}
    tables[rpc][key.to_s] = wire
    mock.instance_variable_set(:@lines, tables)
  end

  def stub_checkin_reply(error_row)
    client = Class.new do
      define_method(:with_context) { |*_a, &b| b.call }
      define_method(:call_rpc) do |*_a|
        [ "T00020ERRORID^T00150MESSAGE#{RS}", error_row, US ]
      end
    end.new
    RpmsRpc.configure { |cfg| cfg.client = client }
  end
end
