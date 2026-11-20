# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/scheduling"
require_relative "../stock_rpcs_test_helper"
require_relative "../captured_replies"

# Supplemental BSDX stock-RPC tests for rpms-rpc#420. The replies are the
# build's: test/fixtures/captured_replies/scheduling-stock-rpcs.yml (a visit
# filed at check-in time, and the check-in and check-out refusals) and the
# scheduler persona's reads in bsdx-scheduling.yml, replayed through
# CiaClient. Each test that reaches the wire checks the gem sent exactly the
# recorded call. The BSDXRPC and CIAV VUECENTRIC binds are proven for every
# method in scheduling_test.rb.
class SchedulingStockRpcsTest < Minitest::Test
  include StockRpcsTestHelper

  SLUG = "scheduling-stock-rpcs"
  START_T = Time.new(2026, 9, 4, 9, 0, 0)

  def setup
    replay
  end

  def teardown
    RpmsRpc.reset!
  end

  # A client with no replies unless a script is given: a test that reaches
  # the wire without one fails.
  def replay(script = {})
    @client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def replay_flow(name) = replay(CapturedReplies.flow_script(SLUG, name))

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  # RESUSR^BSDX01 (BSDX01.m:100-112): with no DUZ given, the signed-on user's.
  def test_resources_by_user_defaults_duz_to_empty_string
    replay("BSDX RESOURCES BY USER" => [ CapturedReplies.raw("bsdx-scheduling", "resources_by_user") ])

    rows = RpmsRpc::Scheduling.resources_by_user

    refute_empty rows
    assert_equal [ [ "BSDX RESOURCES BY USER", [ "" ] ] ], sent
  end

  def test_resources_by_user_is_read_in_retry_safety
    assert_equal :read, RpmsRpc::RetrySafety.for(RpmsRpc::Scheduling, :resources_by_user)
  end

  # Check-in visit: a host cannot obtain the visit IEN (CHECKIN^BSDX25 never
  # returns it), so the lookup is by patient, clinic and check-in time through
  # BEHOENCX FETCH with CREATE=0 (FETCH^BEHOENCX, VSTR2VIS -> FNDVIS with
  # IN("NEVER ADD") set, BEHOENCX.m:24-47, :80). FNDVIS searches the one
  # patient's visits, and VIS2VSTR refuses a visit owned by another patient
  # (BEHOENCX.m:118), so there is no cross-patient read. The capture filed a
  # visit for synthetic DFN 990054 at clinic 3 at 3261118.1000 first.
  DFN = 990_054
  CHECKIN_FM = "3261118.1000"
  CHECKIN_T = Time.new(2026, 11, 18, 10, 0, 0)

  def test_checkin_visit_resolves_by_patient_clinic_and_time_with_create_zero
    replay_flow("checkin_visit_found")

    visit = RpmsRpc::Scheduling.checkin_visit(dfn: DFN, clinic_ien: 3, checkin_time: CHECKIN_T)

    assert_equal 119, visit[:visit_ien]
    assert_equal DFN, visit[:patient_dfn]
    assert_equal 3, visit[:location_ien]
    assert_equal "DEMO IHS CLINIC", visit[:location_name]
    assert_equal CapturedReplies.flow_calls(SLUG, "checkin_visit_found"), sent
    assert_equal [ "990054", "3;#{CHECKIN_FM};A", "", "0" ], sent.sole.last
  end

  def test_checkin_visit_accepts_a_preformatted_fileman_time
    replay_flow("checkin_visit_found")
    RpmsRpc::Scheduling.checkin_visit(dfn: "990054", clinic_ien: "3", checkin_time: CHECKIN_FM)

    assert_equal CapturedReplies.flow_calls(SLUG, "checkin_visit_found"), sent
  end

  def test_checkin_visit_result_does_not_echo_the_request_time_as_visit_data
    replay_flow("checkin_visit_found")
    visit = RpmsRpc::Scheduling.checkin_visit(dfn: DFN, clinic_ien: 3, checkin_time: CHECKIN_T)

    refute visit.key?(:datetime_raw)
    assert_equal %i[location_ien location_name locked patient_dfn visit_id visit_ien], visit.keys.sort
  end

  # No visit at that time: the build's miss is a populated header with empty
  # pieces 6-9 (BEHOENCX.m:41-46), captured for seed DFN 4 at clinic 3.
  def test_checkin_visit_returns_nil_on_the_real_miss_shape
    replay("BEHOENCX FETCH" => [ CapturedReplies.raw("bsdx-scheduling", "checkin_visit") ])

    assert_nil RpmsRpc::Scheduling.checkin_visit(dfn: 4, clinic_ien: 3, checkin_time: "3261109.0801")
  end

  def test_checkin_visit_rejects_a_bad_dfn_clinic_or_time_before_the_wire
    bad = [
      { dfn: nil, clinic_ien: 44, checkin_time: START_T },
      { dfn: "0", clinic_ien: 44, checkin_time: START_T },
      { dfn: "12;3", clinic_ien: 44, checkin_time: START_T },
      { dfn: 990_031, clinic_ien: nil, checkin_time: START_T },
      { dfn: 990_031, clinic_ien: "4;4", checkin_time: START_T },
      { dfn: 990_031, clinic_ien: 0, checkin_time: START_T },
      { dfn: 990_031, clinic_ien: 44, checkin_time: nil },
      { dfn: 990_031, clinic_ien: 44, checkin_time: "" },
      { dfn: 990_031, clinic_ien: 44, checkin_time: "3260904.09;A" },
      { dfn: 990_031, clinic_ien: 44, checkin_time: "tomorrow" },
      { dfn: 990_031, clinic_ien: 44, checkin_time: Date.new(2026, 9, 4) },
      { dfn: 990_031, clinic_ien: 44, checkin_time: "3260904" }
    ]
    bad.each do |args|
      assert_raises(ArgumentError, "expected #{args.inspect} to be refused") do
        RpmsRpc::Scheduling.checkin_visit(**args)
      end
    end
    assert_empty @client.calls
  end

  def test_checkin_visit_no_longer_takes_a_visit_ien
    assert_raises(ArgumentError) { RpmsRpc::Scheduling.checkin_visit(visit_ien: 44_101) }
  end

  def test_checkin_visit_is_read_in_retry_safety
    assert_equal :read, RpmsRpc::RetrySafety.for(RpmsRpc::Scheduling, :checkin_visit)
  end

  READ_GET_ROUTES = File.join(__dir__, "../../fixtures/openapi/read_get_catalog_routes.tsv").freeze

  # A read; the OpenAPI catalog publishes it as GET (read_get_catalog_routes.tsv).
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
    refute_includes path, "visit_ien", "the route must not take a visit IEN"
  end

  # CHECKIN^BSDX25 (BSDX25.m:24-25): a non-numeric and an unknown IEN are
  # both "Invalid Appointment ID".
  def test_checkin_appointment_non_numeric_id_returns_invalid_appointment_id
    replay_flow("checkin_non_numeric")

    result = RpmsRpc::Scheduling.checkin_appointment("abc", checkin_time: "3261118.1101")

    refute result[:success]
    assert_equal "Invalid Appointment ID", result[:error]
    assert_equal CapturedReplies.flow_calls(SLUG, "checkin_non_numeric"), sent
  end

  def test_checkin_appointment_unknown_numeric_id_returns_invalid_appointment_id
    replay_flow("checkin_unknown")

    result = RpmsRpc::Scheduling.checkin_appointment(999_999, checkin_time: "3261118.1101")

    refute result[:success]
    assert_equal "Invalid Appointment ID", result[:error]
    assert_equal CapturedReplies.flow_calls(SLUG, "checkin_unknown"), sent
  end

  # The capture booked an appointment and never checked it in (BSDX25B.m:28).
  def test_checkout_appointment_invalid_reply_is_not_success
    replay_flow("checkout_not_checked_in")
    id = CapturedReplies.flow_calls(SLUG, "checkout_not_checked_in").sole.last[3]

    result = RpmsRpc::Scheduling.checkout_appointment(
      id, patient_dfn: DFN, appointment_time: "3261118.1100", checkout_time: "3261118.1110"
    )

    refute result[:success]
    assert_equal "BSDX25B: Patient not checked in", result[:error]
    assert_equal CapturedReplies.flow_calls(SLUG, "checkout_not_checked_in"), sent
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
end
