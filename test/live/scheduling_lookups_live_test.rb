# frozen_string_literal: true

require_relative "live_helper"
require_relative "seed_clinic"
require "rpms_rpc/api/scheduling_lookups"
require "rpms_rpc/api/agg_lookups"

# The Windows scheduling client's lookups beside the calendar (BSDX under
# BSDXRPC), as the scheduler (PROFILE,SCHED), on what the demo image builds
# (openrpms docs/DEMO-CLINIC.md): the DEMO IHS CLINIC resource group with the
# six demo clinics, the access blocks SEEDBSDX lays 08:00-17:00 on weekdays,
# and the panel patient QUEBEC,SAGE (DFN 990017, HRN 990017). Reads only;
# the reads that need an appointment are SchedulingLookupsBookedLiveTest below.
class SchedulingLookupsLiveTest < LiveSpec::Test
  runs_as :scheduler

  S = RpmsRpc::Scheduling
  DFN = 990_017
  OPERATOR_DUZ = 4 # MANAGER,SYSTEM on every demo build
  DEMO_IHS_CLINIC = 3 # #44, the location of the DEMO IHS CLINIC resource

  def test_the_users_who_schedule_and_the_manager_check
    assert_includes S.schedule_users, { id: OPERATOR_DUZ, name: "MANAGER,SYSTEM" }
    refute S.schedule_users.any? { |u| u[:name] == "PROFILE,SCHED" }, "PROFILE,SCHED holds SDZMENU, not BSDXZMENU"
    refute S.scheduling_manager?, "the scheduler holds no BSDXZMGR"
    assert S.scheduling_manager?(duz: OPERATOR_DUZ), "the operator holds XUPROGMODE"
  end

  def test_the_resource_groups_hold_the_demo_clinics
    assert_includes S.user_resource_groups, { id: 1, name: "DEMO IHS CLINIC" }

    members = S.user_resource_group_members.select { |m| m[:group] == "DEMO IHS CLINIC" }
    assert_equal [ "DEMO BEHAVIORAL HEALTH", "DEMO DIABETES", "DEMO IHS CLINIC", "DEMO PODIATRY", "DEMO PRIMARY CARE", "DEMO SAME DAY" ],
                 members.map { |m| m[:resource] }.sort
    members.each { |m| assert_operator m[:resource_id], :positive? }
  end

  def test_resource_letters_name_each_resource_and_no_letter
    letters = S.resource_letters([ 1, 2 ])
    assert_equal [ "DEMO PRIMARY CARE", "DEMO IHS CLINIC" ], letters.map { |l| l[:name] }
    letters.each { |l| assert_nil l[:letter], "the demo clinics name no letter (DEMO-CLINIC.md, Letters)" }
  end

  def test_a_patient_is_found_and_has_no_no_shows
    assert_equal [ { dfn: DFN, name: "QUEBEC,SAGE", hrn: "990017", dob: Date.new(2001, 6, 9) } ], S.patient_lookup("QUEBEC,SAGE")
    assert_equal({ patient_dfn: DFN, clinic_ien: DEMO_IHS_CLINIC, too_many: false, allowed: 1, total: 0 },
                 S.no_show_count(DFN, DEMO_IHS_CLINIC))
  end

  def test_an_hour_on_a_weekday_overlaps_the_seeded_access_block
    day = next_weekday(Date.today + 7)
    blocks = S.access_block_overlaps(resource: "DEMO PRIMARY CARE", start_time: at(day, 9), end_time: at(day, 10))

    refute_empty blocks, "SEEDBSDX lays a block 08:00-17:00 on #{day}"
    block = blocks.first
    assert_equal "DEMO PRIMARY CARE", block[:resource]
    assert_operator block[:start_time], :<=, at(day, 9)
    assert_operator block[:end_time], :>=, at(day, 10)
    assert_empty S.access_block_overlaps(resource: "DEMO PRIMARY CARE", start_time: at(day + (6 - day.wday), 9),
                                         end_time: at(day + (6 - day.wday), 10)), "no block on a Saturday"
  end

  def test_the_wellness_handout_types
    assert_includes S.wellness_handout_types, { id: 1, name: "ADULT REGULAR" }
  end

  private

  def at(day, hour) = Time.new(day.year, day.month, day.day, hour, 0, 0)

  def next_weekday(day)
    day += 1 while day.saturday? || day.sunday?
    day
  end
end

# The reads a booking shows up in: the patient's appointment history, the
# clinic's reminder-letter list, the appointments an hour overlaps, and, once
# the clinic cancels it, the cancellation-letter list. One appointment is
# booked for the panel patient TANGO,MARLOWE (DFN 990020) at DEMO PRIMARY CARE on a weekday two to
# five weeks out and cancelled by the clinic in ensure, as the scheduling
# client undoes a booking; the cancelled appointment stays on file, as
# every cancellation does.
class SchedulingLookupsBookedLiveTest < LiveSpec::Test
  include LiveSpec::SeedClinic

  runs_as :scheduler
  writes!

  S = RpmsRpc::Scheduling
  PATIENT = 990_020
  RESOURCE = "DEMO PRIMARY CARE"
  CLINIC_CANCELLED = "13" # a clinic-type CANCELLATION REASON (#409.2)

  def test_a_booking_shows_in_the_history_letters_and_overlaps_and_its_cancellation_in_the_cancel_list
    start, id = book!
    day = start.to_date
    begin
      event = S.appointment_events(PATIENT).find { |e| e[:appt_time] == start.strftime("%b %d, %Y %H:%M") } ||
              flunk("appointment at #{start} is not in DFN #{PATIENT}'s event log")
      assert_equal "TANGO,MARLOWE", event[:patient_name]
      assert_equal seed_clinic_ien.to_s, event[:clinic_ien]

      letter = S.appointment_letter_list([ resource_id ], start_date: day, end_date: day).find { |l| l[:appointment_time] == start } ||
               flunk("appointment at #{start} is not on the letter list")
      assert_equal "TANGO,MARLOWE", letter[:name]
      assert_equal RESOURCE, letter[:clinic]
      assert_equal "PROFILE,SCHED", letter[:made_by]

      overlaps = S.appointment_overlaps(resource: RESOURCE, start_time: start, end_time: start + 900)
      assert_includes overlaps.map { |o| o[:patient_dfn] }, PATIENT
    ensure
      cancelled = S.cancel_appointment(id, reason: CLINIC_CANCELLED, type: "C", note: "live spec")
    end
    assert cancelled[:success], "the clinic cancellation of #{id} failed: #{cancelled.inspect}"
    cancelled_rows = S.cancellation_letter_list([ resource_id ], start_date: day, end_date: day)
    assert(cancelled_rows.any? { |r| r[:name] == "TANGO,MARLOWE" && r[:old_appointment_time] == start },
           "the cancelled appointment is not on the cancellation list: #{cancelled_rows.map { |r| r.slice(:name, :old_appointment_time) }}")
    refute_includes S.appointment_overlaps(resource: RESOURCE, start_time: start, end_time: start + 900).map { |o| o[:patient_dfn] }, PATIENT
  end

  private

  def resource_id
    @resource_id ||= (S.resources.find { |r| r[:name] == RESOURCE } || flunk("no BSDX resource #{RESOURCE}"))[:id]
  end

  def book!
    40.times do
      day = Date.today + 14 + rand(21)
      day += 1 while day.saturday? || day.sunday?
      start = Time.new(day.year, day.month, day.day, 8 + rand(8), [ 0, 20, 40 ].sample(random: LiveSpec.random))
      reply = S.add_appointment(patient_dfn: PATIENT, resource: RESOURCE, start_time: start, end_time: start + 1200, length_minutes: 20)
      return [ start, reply[:appointment_id] ] if reply && reply[:success]
    end
    flunk "no weekday two to five weeks out took a booking for DFN #{PATIENT} on #{RESOURCE}"
  end
end

# The registration GUI's lookups (AGG under AGGRPC), as the front desk clerk
# (PROFILE,REG) and, for the key check, the registration supervisor.
class AggLookupsLiveTest < LiveSpec::Test
  runs_as :front_desk_clerk, :registration_supervisor

  A = RpmsRpc::Agg

  def test_the_package_version_and_the_division_parameters
    version = A.version_info
    assert_equal "AG", version[:package]
    assert_equal "7.1", version[:version]
    assert_operator version[:last_patch].to_i, :>=, 17, "AG*7.1*17 gates the SSN edit (openrpms DEMO-CLINIC.md)"
    assert_equal({ complete: true }, A.division_parameters, "the demo division's REGISTRATION PARAMETERS are complete")
  end

  def test_the_reports_menu_names_each_report_rpc
    reports = A.reports.to_h { |r| [ r[:name], r[:rpc] ] }
    assert_equal "AGG PATIENT FACE SHEET", reports["Face Sheet"]
    assert_equal "AGG DAILY REG ACTIVITY REPORT", reports["Daily Report"]
  end

  def test_a_table_field_picks_from_the_panel
    patients = A.table_entries(9_000_001)
    assert_includes patients, { ien: 990_017, name: "QUEBEC,SAGE" }
    assert_includes patients, { ien: 990_001, name: "ALPHA,CASEY" }
  end

  def test_the_mini_registration_window_is_defined
    fields = A.window_definition("Mini Registration")
    refute_empty fields
    assert(fields.all? { |f| f[:vfile_name] == "Mini Registration" })
    assert_equal "AGG ADD NEW PATIENT", fields.first[:edit_rpc]
    assert_equal "AGG WINDOW DATA VALIDATION", fields.first[:valid_rpc]
    assert_empty A.window_definition("NO SUCH WINDOW")
  end

  # AGZMGR is the supervisor's (README, Test roles): the clerk is told no.
  def test_the_key_check_answers_for_the_role
    assert_equal({ held: true }, A.key_held("AGZMENU"))
    if role == :registration_supervisor
      assert_equal({ held: true }, A.key_held("AGZMGR"))
    else
      assert_equal({ held: false, message: "User does not have key AGZMGR" }, A.key_held("AGZMGR"))
    end
  end
end

# Neither option reaches a role whose row lacks it (README, Test roles): the
# BH provider holds no BSDXRPC and no AGGRPC, so every lookup is refused.
class SchedulingAggLookupsRefusedLiveTest < LiveSpec::Test
  runs_as :bh_provider

  S = RpmsRpc::Scheduling
  A = RpmsRpc::Agg
  CALLS = {
    schedule_users: -> { S.schedule_users }, scheduling_manager?: -> { S.scheduling_manager? },
    user_resource_groups: -> { S.user_resource_groups }, user_resource_group_members: -> { S.user_resource_group_members },
    resource_letters: -> { S.resource_letters([ 1 ]) }, no_show_count: -> { S.no_show_count(990_017, 3) },
    patient_lookup: -> { S.patient_lookup("QUEBEC") },
    appointment_events: -> { S.appointment_events(990_020) },
    appointment_letter_list: -> { S.appointment_letter_list([ 1 ], start_date: Date.today, end_date: Date.today) },
    cancellation_letter_list: -> { S.cancellation_letter_list([ 1 ], start_date: Date.today, end_date: Date.today) },
    appointment_overlaps: -> { S.appointment_overlaps(resource: "DEMO PRIMARY CARE", start_time: Time.now, end_time: Time.now + 900) },
    access_block_overlaps: -> { S.access_block_overlaps(resource: "DEMO PRIMARY CARE", start_time: Time.now, end_time: Time.now + 900) },
    wellness_handout_types: -> { S.wellness_handout_types },
    version_info: -> { A.version_info }, division_parameters: -> { A.division_parameters }, reports: -> { A.reports },
    table_entries: -> { A.table_entries(9_000_001) }, window_definition: -> { A.window_definition("Mini Registration") },
    key_held: -> { A.key_held("AGZMENU") }
  }.freeze

  def test_every_lookup_is_refused_without_the_option
    answered = CALLS.filter_map do |name, call|
      call.call
      name
    rescue RpmsRpc::Client::RpcRefusedError, RpmsRpc::Client::ContextRefusedError
      nil
    end
    assert_empty answered, "#{role} holds neither BSDXRPC nor AGGRPC and these answered: #{answered.join(', ')}"
  end
end
