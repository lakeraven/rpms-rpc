# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/scheduling"
require_relative "../captured_replies"

# Tests for RpmsRpc::Scheduling, the BSDX scheduling surface the
# lakeraven-ehr reg/sched twin consumes (lakeraven-ehr#412).
#
# Replies are the pinned build's, captured as the scheduler persona on a
# throwaway container (test/fixtures/captured_replies/bsdx-scheduling.yml) and
# replayed through CiaClient: the demo clinic's reads, then one appointment
# (A) taken through check-in, check-out, no-show, cancel and uncancel, with
# the routines' own refusals. Each test sends what the gem sends and asserts
# it equals what was sent when the reply was captured. The live specs
# (test/live/scheduling_*_live_test.rb) prove the round trips.
class SchedulingTest < Minitest::Test
  SLUG = "bsdx-scheduling"
  CLINIC = "DEMO IHS CLINIC"
  DFN = 4

  def self.inputs_of(name) = CapturedReplies.file(SLUG).fetch("captures").find { |c| c["name"] == name }.fetch("inputs")
  APPT = inputs_of("checkin").first # appointment A, booked in the capture's setup
  MISSING = "999999"

  A_START = Time.new(2026, 11, 9, 8, 0, 0)
  B_START = Time.new(2026, 11, 16, 9, 0, 0)
  B_END   = Time.new(2026, 11, 16, 9, 15, 0)

  # A CiaClient answering each RPC with the named captures, in order, that
  # records the option bound when each RPC went out.
  class Replay < CapturedReplies::ReplayCiaClient
    def call_rpc_raw(rpc_name, *params)
      super.tap { @calls.last[:context] = current_context }
    end

    def starting_on(context)
      @current_context = context
      self
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    @client = Replay.new(script.transform_values { |names| Array(names).map { |n| CapturedReplies.raw(SLUG, n) } })
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = @client }
    @client
  end

  def sent(rpc)
    call = @client.calls.find { |c| c[:rpc] == rpc }
    refute_nil call, "#{rpc} was not called"
    call[:params]
  end

  def inputs_of(name) = self.class.inputs_of(name)

  # ===========================================================================
  # ADD (book)
  # ===========================================================================

  # START^END^DFN^RESOURCE^LENGTH^NOTE^ACCESS_TYPE^CHART_REQUEST (APPADD^BSDX07).
  def test_add_appointment_books_and_sends_the_captured_parameters
    replay("BSDX ADD NEW APPOINTMENT" => "add")

    result = RpmsRpc::Scheduling.add_appointment(
      patient_dfn: DFN, resource: CLINIC, start_time: B_START, end_time: B_END, length_minutes: 15, note: "synthetic"
    )

    assert result[:success]
    assert result[:appointment_id].positive?
    assert_equal inputs_of("add"), sent("BSDX ADD NEW APPOINTMENT")
  end

  def test_add_appointment_sends_access_type_and_chart_request_last
    replay("BSDX ADD NEW APPOINTMENT" => "add")

    RpmsRpc::Scheduling.add_appointment(
      patient_dfn: DFN, resource: CLINIC, start_time: B_START, end_time: B_END, length_minutes: 15,
      note: "synthetic", access_type: "WALKIN", chart_request: true
    )

    assert_equal inputs_of("add")[0..5] + [ "WALKIN", "1" ], sent("BSDX ADD NEW APPOINTMENT")
  end

  # Regression: DateTime < Date in Ruby, so a `when Date` branch listed before
  # `when Time` swallowed DateTime inputs and formatted them date-only,
  # silently booking appointments with no time of day.
  def test_add_appointment_datetime_keeps_time_of_day_regression
    replay("BSDX ADD NEW APPOINTMENT" => "add")

    RpmsRpc::Scheduling.add_appointment(
      patient_dfn: DFN, resource: CLINIC, start_time: DateTime.new(2026, 11, 16, 9, 0, 0),
      end_time: DateTime.new(2026, 11, 16, 9, 15, 0), length_minutes: 15, note: "synthetic"
    )

    assert_equal inputs_of("add").first(2), sent("BSDX ADD NEW APPOINTMENT").first(2)
  end

  def test_add_appointment_on_an_unknown_resource_returns_the_routines_error
    replay("BSDX ADD NEW APPOINTMENT" => "add_unknown_resource")

    result = RpmsRpc::Scheduling.add_appointment(
      patient_dfn: DFN, resource: "NO SUCH RESOURCE", start_time: B_START, end_time: B_END, length_minutes: 15
    )

    refute result[:success]
    assert_equal "BSDX07 Error: Invalid Resource ID", result[:error]
  end

  # ===========================================================================
  # CANCEL / UNCANCEL (empty ERRORID == success)
  # ===========================================================================

  def test_cancel_appointment_sends_id_type_reason_and_note
    replay("BSDX CANCEL APPOINTMENT" => "cancel")

    result = RpmsRpc::Scheduling.cancel_appointment(APPT, reason: 1, type: "C", note: "moved")

    assert result[:success]
    assert_equal inputs_of("cancel"), sent("BSDX CANCEL APPOINTMENT")
  end

  def test_cancel_appointment_failure_passes_through_message
    replay("BSDX CANCEL APPOINTMENT" => "cancel_missing")

    result = RpmsRpc::Scheduling.cancel_appointment(MISSING, reason: 1)

    refute result[:success]
    assert_equal "BSDX08: Invalid Appointment ID", result[:error]
  end

  def test_uncancel_appointment_success
    replay("BSDX UNCANCEL APPT" => "uncancel")

    assert RpmsRpc::Scheduling.uncancel_appointment(APPT)[:success]
    assert_equal [ APPT ], sent("BSDX UNCANCEL APPT")
  end

  # APPUDEL^BSDX08 refuses to restore a patient-cancelled appointment, but its
  # second TROLLBACK (inside ERR) is an M error on YottaDB, so the broker
  # answers that error instead of the routine's message. It must raise, not
  # read as a restored appointment.
  def test_uncancel_of_a_patient_cancelled_appointment_raises_the_m_error
    replay("BSDX UNCANCEL APPT" => "uncancel_patient_cancelled")

    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Scheduling.uncancel_appointment(APPT) }
  end

  # ===========================================================================
  # CHECK-IN ("0^" success row) and UNDO CHECK-IN
  # ===========================================================================

  # All 8 formals of CHECKIN^BSDX25 (APTID^CDT^CC^PRV^ROU^VCL^VFM^OG) are sent,
  # trailing ones empty: the routine passes VCL/VFM/OG by value with no $G
  # (BSDX25.m:63), so a 4-param call dies with <UNDEF> when the resource links
  # a hospital location. The live success row is "0^"_EMSG (BSDX25.m:74).
  def test_checkin_appointment_sends_all_eight_formals_and_reads_zero_caret_as_success
    replay("BSDX CHECKIN APPOINTMENT" => "checkin")

    result = RpmsRpc::Scheduling.checkin_appointment(APPT, checkin_time: A_START + 60)

    assert result[:success], "\"0^\" ERRORID row is a successful check-in"
    assert_equal inputs_of("checkin"), sent("BSDX CHECKIN APPOINTMENT")
  end

  # A failure row is the single-piece error text ERR^BSDX25 writes (BSDX25.m:361-365).
  def test_checkin_appointment_failure_row
    replay("BSDX CHECKIN APPOINTMENT" => "checkin_missing")

    result = RpmsRpc::Scheduling.checkin_appointment(MISSING, checkin_time: A_START + 60)

    refute result[:success]
    assert_equal "Invalid Appointment ID", result[:error]
  end

  def test_cancel_checkin_sends_at_sign_as_the_checkin_time
    replay("BSDX CHECKIN APPOINTMENT" => "cancel_checkin")

    assert RpmsRpc::Scheduling.cancel_checkin(APPT)[:success]
    assert_equal inputs_of("cancel_checkin"), sent("BSDX CHECKIN APPOINTMENT")
  end

  # ===========================================================================
  # CHECK-OUT and UNDO CHECK-OUT
  # ===========================================================================

  def test_checkout_appointment_sends_dfn_times_and_id_in_checkout_order
    replay("BSDX CHECKOUT APPOINTMENT" => "checkout")

    result = RpmsRpc::Scheduling.checkout_appointment(APPT, patient_dfn: DFN, appointment_time: A_START,
                                                            checkout_time: A_START + 600)

    assert result[:success]
    assert_equal inputs_of("checkout"), sent("BSDX CHECKOUT APPOINTMENT")
  end

  def test_checkout_in_the_future_is_refused_with_the_routines_reason
    replay("BSDX CHECKOUT APPOINTMENT" => "checkout_future")

    result = RpmsRpc::Scheduling.checkout_appointment(APPT, patient_dfn: DFN, appointment_time: A_START,
                                                            checkout_time: Time.new(2026, 12, 1, 9, 0, 0))

    refute result[:success]
    assert_equal "Check Out time cannot be in the future.", result[:error]
  end

  def test_cancel_checkout_success_and_refusal
    replay("BSDX CANCEL CHECKOUT APPT" => [ "cancel_checkout", "cancel_checkout_not_checked_out" ])

    assert RpmsRpc::Scheduling.cancel_checkout(APPT)[:success]
    assert_equal [ APPT ], sent("BSDX CANCEL CHECKOUT APPT")

    result = RpmsRpc::Scheduling.cancel_checkout(APPT)
    refute result[:success]
    assert_equal "Appointment is not Checked Out.", result[:error]
  end

  # ===========================================================================
  # NO-SHOW (INVERTED polarity: result 1 == success) and EDIT
  # ===========================================================================

  def test_mark_and_clear_no_show
    replay("BSDX NOSHOW" => [ "no_show", "clear_no_show" ])

    assert RpmsRpc::Scheduling.mark_no_show(APPT)[:success]
    assert RpmsRpc::Scheduling.mark_no_show(APPT, no_show: false)[:success]
    assert_equal [ inputs_of("no_show"), inputs_of("clear_no_show") ], @client.calls.select { |c| c[:rpc] == "BSDX NOSHOW" }.map { |c| c[:params] }
  end

  def test_mark_no_show_failure_result_zero
    replay("BSDX NOSHOW" => "no_show_missing")

    result = RpmsRpc::Scheduling.mark_no_show(MISSING)

    refute result[:success]
    assert_match(/Invalid Appointment ID/, result[:error])
  end

  def test_edit_appointment_sends_note_and_length
    replay("BSDX EDIT APPOINTMENT" => "edit")

    assert RpmsRpc::Scheduling.edit_appointment(APPT, note: "synthetic edit", length_minutes: 20)[:success]
    assert_equal inputs_of("edit"), sent("BSDX EDIT APPOINTMENT")
  end

  # ===========================================================================
  # AVAILABILITY WRITES
  # ===========================================================================

  def test_add_availability_returns_the_new_block
    replay("BSDX ADD NEW AVAILABILITY" => "add_availability")

    result = RpmsRpc::Scheduling.add_availability(resource: CLINIC, start_time: Time.new(2026, 12, 7, 8, 0, 0),
                                                  end_time: Time.new(2026, 12, 7, 12, 0, 0), slots: 2, access_type_id: 1)

    assert result[:success]
    assert result[:availability_id].positive?
    assert_equal inputs_of("add_availability"), sent("BSDX ADD NEW AVAILABILITY")
  end

  def test_cancel_availability_by_date
    replay("BSDX CANCEL AV BY DATE" => "cancel_availability")

    assert RpmsRpc::Scheduling.cancel_availability_by_date(resource_id: 2, start_date: Date.new(2026, 12, 7),
                                                           end_date: Date.new(2026, 12, 7))[:success]
    assert_equal inputs_of("cancel_availability"), sent("BSDX CANCEL AV BY DATE")
  end

  # ===========================================================================
  # READS
  # ===========================================================================

  # SEARCH^BSDX24 writes the DATE column in external format (DD^%DT,
  # BSDX24.m:116-117) and ends the row after ACCESSTYPE (BSDX24.m:124).
  def test_availability_returns_blocks_with_external_dates
    replay("BSDX SEARCH AVAILABILITY" => "availability")

    blocks = RpmsRpc::Scheduling.availability(resources: CLINIC, start_date: Date.new(2026, 11, 16),
                                              end_date: Date.new(2026, 11, 16))

    refute_empty blocks
    assert(blocks.all? { |b| b[:resource_name] == CLINIC && b[:date] == Date.new(2026, 11, 16) })
    assert_nil blocks.first[:comment]
    assert_equal inputs_of("availability"), sent("BSDX SEARCH AVAILABILITY")
  end

  # RESOURCE_NAMES^START^END^ACCESS_TYPES^AMPM^WEEKDAYS, resources joined by "|".
  def test_availability_joins_resources_and_sends_the_filters
    replay("BSDX SEARCH AVAILABILITY" => "availability")

    RpmsRpc::Scheduling.availability(resources: [ CLINIC, "DEMO PRIMARY CARE" ], start_date: Date.new(2026, 11, 16),
                                     end_date: Date.new(2026, 11, 16), access_types: "1|2", ampm: "AM", weekdays: "1|2|3")

    assert_equal [ "#{CLINIC}|DEMO PRIMARY CARE", "3261116", "3261116", "1|2", "AM", "1|2|3" ],
                 sent("BSDX SEARCH AVAILABILITY")
  end

  def test_availability_for_an_unknown_resource_is_empty
    replay("BSDX SEARCH AVAILABILITY" => "availability_unknown_resource")

    assert_equal [], RpmsRpc::Scheduling.availability(resources: "NO SUCH RESOURCE", start_date: Date.new(2026, 11, 16),
                                                      end_date: Date.new(2026, 11, 16))
  end

  def test_availability_rejects_pipe_in_resource_name
    replay({})

    err = assert_raises(ArgumentError) do
      RpmsRpc::Scheduling.availability(resources: [ "#{CLINIC}|SMUGGLED,RES" ], start_date: Date.new(2026, 11, 16),
                                       end_date: Date.new(2026, 11, 16))
    end
    assert_match(/must not contain '\|'/, err.message)
    assert_empty @client.calls, "no RPC should be sent"
  end

  # APBLKALL^BSDX05 writes external datetimes (BSDX05.m:100-101) and a 4th
  # RES_NAME column per row (BSDX05.m:65,76).
  def test_all_appointments_parses_external_datetimes_and_resource
    replay("BSDX ALL APPOINTMENTS" => "all_appointments")

    rows = RpmsRpc::Scheduling.all_appointments(start_date: Date.new(2026, 11, 9), end_date: Date.new(2026, 11, 9))

    row = rows.find { |r| r[:start_time] == A_START }
    refute_nil row, rows.inspect
    assert_equal A_START + 900, row[:end_time]
    assert_equal DFN, row[:patient_dfn]
    assert_equal CLINIC, row[:resource_name]
  end

  def test_all_appointments_on_a_day_with_none_is_empty
    replay("BSDX ALL APPOINTMENTS" => "all_appointments_none")

    assert_equal [], RpmsRpc::Scheduling.all_appointments(start_date: Date.new(2026, 11, 17), end_date: Date.new(2026, 11, 17))
  end

  def test_hospital_locations_returns_clinics
    replay("BSDX HOSPITAL LOCATION" => "hospital_locations")

    clinic = RpmsRpc::Scheduling.hospital_locations.find { |c| c[:location] == CLINIC }

    refute_nil clinic
    assert_equal 3, clinic[:location_ien]
    assert_equal "PROFILE,MD", clinic[:default_provider]
    assert_nil clinic[:inactivate_date]
  end

  def test_clinic_setup_returns_each_clinics_parameters
    replay("BSDX CLINIC SETUP" => "clinic_setup")

    row = RpmsRpc::Scheduling.clinic_setup.find { |r| r[:location] == CLINIC }

    refute_nil row
    assert_equal 3, row[:location_ien]
    assert_equal "YES", row[:create_visit]
    assert_equal "AMBULATORY", row[:visit_service_category]
    assert_equal "NO", row[:multiple_clinic_codes]
    assert_equal "YES", row[:visit_provider_required]
    assert_nil row[:generate_pccplus_forms]
    assert_equal 1, row[:max_overbooks]
  end

  def test_resources_and_resources_by_user
    replay("BSDX RESOURCES" => "resources", "BSDX RESOURCES BY USER" => "resources_by_user")

    [ RpmsRpc::Scheduling.resources, RpmsRpc::Scheduling.resources_by_user ].each do |rows|
      clinic = rows.find { |r| r[:name] == CLINIC }
      refute_nil clinic
      assert_equal 2, clinic[:id]
      assert_equal 3, clinic[:hospital_location_id]
      refute clinic[:inactive]
    end
  end

  def test_slot_schedule_and_appointments_on_the_demo_clinic
    replay("BSDX CREATE ASGND SLOT SCHED" => "slot_schedule", "BSDX CREATE APPT SCHEDULE" => "appointments")

    slots = RpmsRpc::Scheduling.slot_schedule(resource: CLINIC, start_date: Date.new(2026, 11, 16), end_date: Date.new(2026, 11, 16))
    appts = RpmsRpc::Scheduling.appointments(resource: CLINIC, start_date: Date.new(2026, 11, 9), end_date: Date.new(2026, 11, 9))

    assert(slots.any? { |s| s[:slots].positive? && s[:resource] == CLINIC })
    assert_equal inputs_of("slot_schedule"), sent("BSDX CREATE ASGND SLOT SCHED")
    a = appts.find { |r| r[:id] == APPT.to_i }
    refute_nil a, appts.inspect
    assert_equal DFN, a[:patient_dfn]
    assert_equal A_START, a[:start_time]
    assert_equal inputs_of("appointments"), sent("BSDX CREATE APPT SCHEDULE")
  end

  def test_overbook_and_variable_length
    replay("BSDX OVERBOOK" => "overbook", "BSDX CLINIC VAR APPT" => "variable_length")

    assert_equal true, RpmsRpc::Scheduling.overbook_allowed(hospital_location_id: 3, start_time: A_START, resource_id: 2)
    assert_equal true, RpmsRpc::Scheduling.variable_length?(3)
    assert_equal inputs_of("overbook"), sent("BSDX OVERBOOK")
  end

  # BEHOENCX FETCH with create flag 0 finds no visit at A's check-in: nil.
  def test_checkin_visit_is_nil_when_no_visit_was_made
    replay("BEHOENCX FETCH" => "checkin_visit")

    assert_nil RpmsRpc::Scheduling.checkin_visit(dfn: DFN, clinic_ien: 3, checkin_time: A_START + 60)
    assert_equal inputs_of("checkin_visit"), sent("BEHOENCX FETCH")
  end

  # -- BSDXRPC context binding (rpms-rpc#258) --------------------------------
  #
  # RPC registration is OPTION-scoped (RpmsRpc::ContextScope). On a built 9.0
  # image every BSDX RPC this module calls sits in the RPC multiple of ONE
  # file-19 option, BSDXRPC, and in none of the options a signed-on session is
  # otherwise holding. Each method binds BSDXRPC around its call and hands the
  # caller's option back, as RpmsRpc::Agg does for AGGRPC.

  START_T = Time.new(2026, 11, 9, 8, 0, 0)
  END_T   = Time.new(2026, 11, 9, 8, 15, 0)

  # Each public method, its arguments, and the captured reply its RPC answers.
  BSDX_CALLS = {
    add_appointment: [ [ { patient_dfn: DFN, resource: CLINIC, start_time: START_T, end_time: END_T, length_minutes: 15 } ],
                       { "BSDX ADD NEW APPOINTMENT" => "add" } ],
    cancel_appointment: [ [ APPT, { reason: 1 } ], { "BSDX CANCEL APPOINTMENT" => "cancel" } ],
    uncancel_appointment: [ [ APPT ], { "BSDX UNCANCEL APPT" => "uncancel" } ],
    checkin_appointment: [ [ APPT, { checkin_time: START_T } ], { "BSDX CHECKIN APPOINTMENT" => "checkin" } ],
    cancel_checkin: [ [ APPT ], { "BSDX CHECKIN APPOINTMENT" => "cancel_checkin" } ],
    checkout_appointment: [ [ APPT, { patient_dfn: DFN, appointment_time: START_T, checkout_time: END_T } ],
                            { "BSDX CHECKOUT APPOINTMENT" => "checkout" } ],
    cancel_checkout: [ [ APPT ], { "BSDX CANCEL CHECKOUT APPT" => "cancel_checkout" } ],
    mark_no_show: [ [ APPT ], { "BSDX NOSHOW" => "no_show" } ],
    patient_appointments: [ [ 999_999_999 ], { "BSDX PATIENT APPT DISPLAY" => "patient_appointments_none" } ],
    availability: [ [ { resources: CLINIC, start_date: START_T, end_date: END_T } ],
                    { "BSDX SEARCH AVAILABILITY" => "availability" } ],
    all_appointments: [ [ { start_date: START_T, end_date: END_T } ], { "BSDX ALL APPOINTMENTS" => "all_appointments" } ],
    hospital_locations: [ [], { "BSDX HOSPITAL LOCATION" => "hospital_locations" } ],
    clinic_setup: [ [], { "BSDX CLINIC SETUP" => "clinic_setup" } ],
    resources: [ [], { "BSDX RESOURCES" => "resources" } ],
    resources_by_user: [ [], { "BSDX RESOURCES BY USER" => "resources_by_user" } ],
    appointments: [ [ { resource: CLINIC, start_date: START_T, end_date: END_T } ],
                    { "BSDX CREATE APPT SCHEDULE" => "appointments" } ],
    slot_schedule: [ [ { resource: CLINIC, start_date: START_T, end_date: END_T } ],
                     { "BSDX CREATE ASGND SLOT SCHED" => "slot_schedule" } ],
    add_availability: [ [ { resource: CLINIC, start_time: START_T, end_time: END_T, slots: 1, access_type_id: 1 } ],
                        { "BSDX ADD NEW AVAILABILITY" => "add_availability" } ],
    cancel_availability_by_date: [ [ { resource_id: 2, start_date: START_T, end_date: END_T } ],
                                   { "BSDX CANCEL AV BY DATE" => "cancel_availability" } ],
    overbook_allowed: [ [ { hospital_location_id: 3, start_time: START_T, resource_id: 2 } ], { "BSDX OVERBOOK" => "overbook" } ],
    edit_appointment: [ [ APPT, { note: "synthetic edit", length_minutes: 20 } ], { "BSDX EDIT APPOINTMENT" => "edit" } ],
    variable_length?: [ [ 3 ], { "BSDX CLINIC VAR APPT" => "variable_length" } ]
  }.freeze

  # BEHOENCX FETCH is not a BSDX RPC. The pinned build serves it only
  # from CIAV VUECENTRIC, so checkin_visit is not in BSDX_CALLS.
  FETCH_CALLS = {
    checkin_visit: [ [ { dfn: DFN, clinic_ien: 3, checkin_time: START_T } ], { "BEHOENCX FETCH" => "checkin_visit" } ]
  }.freeze

  def test_the_bind_table_names_every_public_method
    expected = RpmsRpc::Scheduling.public_instance_methods(false).sort

    assert_equal expected, (BSDX_CALLS.keys + FETCH_CALLS.keys).sort,
      "a new Scheduling method must be added to BSDX_CALLS or FETCH_CALLS so its context bind is proven"
  end

  def test_every_bsdx_call_runs_under_bsdxrpc_and_restores_the_callers_context
    BSDX_CALLS.each do |method, (args, script)|
      run_scoped(method, args, script, caller: "CIAV VUECENTRIC", expect: "BSDXRPC")
    end
  end

  def test_checkin_visit_runs_under_ciav_vuecentric_and_restores_the_callers_context
    FETCH_CALLS.each do |method, (args, script)|
      run_scoped(method, args, script, caller: "BSDXRPC", expect: "CIAV VUECENTRIC")
    end
  end

  # A bind the broker refuses raises before any BSDX RPC is sent.
  def test_a_bsdxrpc_that_will_not_bind_raises_before_any_rpc_is_sent
    refusing = Class.new(Replay) do
      def create_context(option_name = SIGNON_CONTEXT)
        raise RpmsRpc::Client::RpcError, "context refused" if option_name == "BSDXRPC"

        super
      end
    end
    @client = refusing.new("BSDX HOSPITAL LOCATION" => [ CapturedReplies.raw(SLUG, "hospital_locations") ])
    RpmsRpc.configure { |cfg| cfg.client = @client }

    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Scheduling.hospital_locations }
    refute(@client.calls.any? { |c| c[:rpc].is_a?(String) })
  end

  private

  def run_scoped(method, args, script, caller:, expect:)
    replay(script).starting_on(caller)
    positional = args.reject { |a| a.is_a?(Hash) }
    keywords = args.find { |a| a.is_a?(Hash) } || {}

    RpmsRpc::Scheduling.public_send(method, *positional, **keywords)

    rpcs = @client.calls.select { |c| c[:rpc].is_a?(String) }
    refute_empty rpcs, "#{method} made no RPC call"
    rpcs.each do |call|
      assert_equal expect, call[:context], "#{method} sent #{call[:rpc]} under #{call[:context].inspect}"
    end
    assert_equal caller, @client.current_context, "#{method} left the session on #{@client.current_context.inspect}"
    binds = @client.calls.select { |c| c[:rpc] == :create_context }.map { |c| c[:params].first }
    assert_equal [ expect, caller ], binds, "#{method}: expected one bind and one restore"
  end
end
