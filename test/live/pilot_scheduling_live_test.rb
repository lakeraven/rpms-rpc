# frozen_string_literal: true

require_relative "live_helper"
require "date"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/scheduling_setup"
require "rpms_rpc/api/ddr_fileman"

# Booking and checking in on a real build, as the pilot stories' roles
# (openrpms-ux S-SCH-01, S-SCH-03). Each books MOUSE,MICKEY M (DFN 3) on
# DEMO IHS CLINIC, so it runs on a disposable container only.
module PilotSchedulingLive
  PATIENT = 3 # MOUSE,MICKEY M, on every demo build
  CLINIC = "DEMO IHS CLINIC"

  # The first open quarter hour on +day+ between 08:00 and 16:45, booked.
  def book_on(day)
    (8..16).to_a.product([ 0, 15, 30, 45 ]).shuffle.first(40).each do |hour, minute|
      start = Time.new(day.year, day.month, day.day, hour, minute)
      reply = RpmsRpc::Scheduling.add_appointment(patient_dfn: PATIENT, resource: CLINIC, start_time: start,
                                                  end_time: start + 900, length_minutes: 15)
      return [ start, reply[:appointment_id] ] if reply && reply[:success]
    end
    flunk "no quarter hour on #{day} took a booking for DFN #{PATIENT} on #{CLINIC}"
  end

  def on_schedule(day, id)
    RpmsRpc::Scheduling.appointments(resource: CLINIC, start_date: day, end_date: day).find { |a| a[:id] == id }
  end

  def in_patient_list(start)
    RpmsRpc::Scheduling.patient_appointments(PATIENT).find { |a| a[:start_time] == start && a[:clinic] == CLINIC }
  end
end

# S-SCH-01.1: a slot on a clinic with open slots, picked for a registered
# patient, shows on the clinic's schedule and in the patient's appointments.
class PilotBookAppointmentLiveTest < LiveSpec::Test
  runs_as :scheduler
  proves "S-SCH-01.1"
  writes!
  include PilotSchedulingLive

  def test_a_booked_slot_shows_on_the_clinic_schedule_and_in_the_patients_appointments
    day = Date.today + 7 + rand(14)
    day += 1 while day.saturday? || day.sunday?
    start, id = book_on(day)

    booked = on_schedule(day, id)
    assert booked, "appointment #{id} is on #{CLINIC}'s schedule for #{day}"
    assert_equal [ start, PATIENT, false ], booked.values_at(:start_time, :patient_dfn, :cancelled)
    assert_equal "scheduled", in_patient_list(start)&.fetch(:status), "the patient's appointments list it, scheduled"
  end
end

# S-SCH-03.9: a checked-in appointment's check-in is undone, so the clinic
# holds no check-in time and the appointment is scheduled again.
class PilotUndoCheckinLiveTest < LiveSpec::Test
  runs_as :front_desk_clerk
  proves "S-SCH-03.9"
  writes!
  include PilotSchedulingLive

  def test_undoing_a_check_in_clears_it_and_the_appointment_is_scheduled_again
    day = Date.today
    start, id = book_on(day)
    assert RpmsRpc::Scheduling.checkin_appointment(id, checkin_time: Time.now - 60)[:success]
    refute_nil on_schedule(day, id)[:checkin_time], "checked in"
    assert_equal "checked in", in_patient_list(start)[:status]

    assert RpmsRpc::Scheduling.cancel_checkin(id)[:success]

    assert_nil on_schedule(day, id)[:checkin_time], "the clinic holds no check-in time"
    assert_equal "scheduled", in_patient_list(start)[:status]
  end
end

# S-SCH-02.1: a booked appointment cancelled with a reason, by the patient,
# leaves the slot open again and PATIENT (#2.98) marked cancelled by the
# patient with that reason. The slot is shown open by booking another patient
# into it. TRAVEL DIFFICULTY is a patient-type CANCELLATION REASON (#409.2)
# on every demo build.
class PilotCancelAppointmentLiveTest < LiveSpec::Test
  runs_as :scheduler
  proves "S-SCH-02.1"
  writes!
  include PilotSchedulingLive

  OTHER_PATIENT = 2
  TRAVEL_DIFFICULTY = "4"

  def test_cancelling_with_a_reason_opens_the_slot_and_records_who_and_why
    day = Date.today + 22 + rand(14)
    day += 1 while day.saturday? || day.sunday?
    start, id = book_on(day)

    assert RpmsRpc::Scheduling.cancel_appointment(id, reason: TRAVEL_DIFFICULTY, type: "PC", note: "live spec")[:success]

    assert on_schedule(day, id)[:cancelled], "the clinic's schedule shows it cancelled"
    assert_equal :patient, RpmsRpc::SchedulingSetup.cancelled_by(start_time: start, patient_dfn: PATIENT)
    filed = RpmsRpc::DdrFileman.gets_entry(file: "2.98", iens: "#{canonical(start)},#{PATIENT},", fields: "3;16", flags: "I")[:fields]
    assert_equal [ "PC", TRAVEL_DIFFICULTY ], [ filed.dig("3", :internal), filed.dig("16", :internal) ]

    again = RpmsRpc::Scheduling.add_appointment(patient_dfn: OTHER_PATIENT, resource: CLINIC, start_time: start,
                                                end_time: start + 900, length_minutes: 15)
    assert again[:success], "the slot is open again: #{again.inspect}"
  end

  private

  # A FileMan date/time with no trailing zeros, as #2.98's IEN is.
  def canonical(time) = RpmsRpc::FilemanDateParser.to_fileman(time).sub(/0+\z/, "").chomp(".")
end

# S-SCH-05.3: a day with appointments of every status shows each with its
# status, and the overbook marked. On a past weekday, so check-out and no-show
# can be filed: one stays scheduled, one is checked in, one checked in and
# out, one cancelled by the patient, one by the clinic, one a no-show, and one
# is marked an overbook (#44.003 field 9). Each is read back from the clinic's
# schedule (BSDX CREATE APPT SCHEDULE) and #2.98's status.
class PilotDayViewLiveTest < LiveSpec::Test
  runs_as :scheduler
  proves "S-SCH-05.3"
  writes!
  include PilotSchedulingLive

  TRAVEL_DIFFICULTY = "4" # a patient-type CANCELLATION REASON (#409.2)
  CLINIC_CANCELLED = "13" # a clinic-type one

  def test_each_status_and_the_overbook_show_on_the_day
    day = Date.today - 10 - rand(40)
    day -= 1 while day.saturday? || day.sunday?
    booked = %i[scheduled checked_in checked_out cancelled_by_patient cancelled_by_clinic no_show overbook]
             .to_h { |status| [ status, book_on(day) ] }
    s = RpmsRpc::Scheduling

    assert s.checkin_appointment(booked[:checked_in][1], checkin_time: booked[:checked_in][0] + 300)[:success]
    out_start, out_id = booked[:checked_out]
    assert s.checkin_appointment(out_id, checkin_time: out_start + 300)[:success]
    assert s.checkout_appointment(out_id, patient_dfn: PATIENT, appointment_time: out_start, checkout_time: out_start + 1800)[:success]
    assert s.cancel_appointment(booked[:cancelled_by_patient][1], reason: TRAVEL_DIFFICULTY, type: "PC", note: "live spec")[:success]
    assert s.cancel_appointment(booked[:cancelled_by_clinic][1], reason: CLINIC_CANCELLED, type: "C", note: "live spec")[:success]
    assert s.mark_no_show(booked[:no_show][1])[:success]
    over_start, = booked[:overbook]
    where = { hospital_location_id: clinic_ien, start_time: over_start, patient_dfn: PATIENT }
    assert RpmsRpc::SchedulingSetup.mark_overbook(**where)[:success]

    row = ->(status) { on_schedule(day, booked[status][1]) }
    assert_equal [ nil, nil, false, false ], row[:scheduled].values_at(:checkin_time, :checkout_time, :cancelled, :no_show)
    refute_nil row[:checked_in][:checkin_time]
    assert_nil row[:checked_in][:checkout_time]
    refute_nil row[:checked_out][:checkout_time]
    assert row[:cancelled_by_patient][:cancelled]
    assert_equal :patient, RpmsRpc::SchedulingSetup.cancelled_by(start_time: booked[:cancelled_by_patient][0], patient_dfn: PATIENT)
    assert row[:cancelled_by_clinic][:cancelled]
    assert_equal :clinic, RpmsRpc::SchedulingSetup.cancelled_by(start_time: booked[:cancelled_by_clinic][0], patient_dfn: PATIENT)
    assert row[:no_show][:no_show]
    assert RpmsRpc::SchedulingSetup.overbook?(**where), "the overbook is marked"
    refute RpmsRpc::SchedulingSetup.overbook?(**where, start_time: booked[:scheduled][0]), "a booking within the slots is not"
  end

  private

  def clinic_ien = RpmsRpc::Scheduling.resources.find { |r| r[:name] == CLINIC }.fetch(:hospital_location_id)
end

# S-SCH-03.1: checking in a patient booked today shows the appointment
# checked in with the time, and leaves a visit for the clinic and date. The
# clinic is DEMO PRIMARY CARE, which creates a visit at check-in. On
# bcer-9.0-20261124-60d39b6-ydb the visit is filed but the EHR's lookup
# (BEHOENCX FETCH) cannot find it: the demo seed's two visit-type parameters
# disagree (openrpms#1342), so the spec skips by that issue there.
class PilotCheckinLiveTest < LiveSpec::Test
  runs_as :front_desk_clerk
  proves "S-SCH-03.1"
  writes!
  include PilotSchedulingLive

  VISIT_CLINIC = "DEMO PRIMARY CARE"

  def test_checking_in_today_shows_the_time_and_leaves_a_visit
    day = Date.today
    start = nil
    id = nil
    (8..16).to_a.product([ 0, 15, 30, 45 ]).shuffle.first(40).each do |hour, minute|
      at = Time.new(day.year, day.month, day.day, hour, minute)
      reply = RpmsRpc::Scheduling.add_appointment(patient_dfn: PATIENT, resource: VISIT_CLINIC, start_time: at,
                                                  end_time: at + 900, length_minutes: 15)
      break (start, id = at, reply[:appointment_id]) if reply && reply[:success]
    end
    flunk "no quarter hour today took a booking on #{VISIT_CLINIC}" unless id
    clinic = RpmsRpc::Scheduling.resources.find { |r| r[:name] == VISIT_CLINIC }.fetch(:hospital_location_id)
    assert RpmsRpc::SchedulingSetup.creates_visit_at_checkin(clinic), "#{VISIT_CLINIC} creates a visit at check-in"

    checkin = Time.now - 60
    assert RpmsRpc::Scheduling.checkin_appointment(id, checkin_time: checkin)[:success]

    listed = RpmsRpc::Scheduling.appointments(resource: VISIT_CLINIC, start_date: day, end_date: day).find { |a| a[:id] == id }
    assert_equal checkin.strftime("%Y-%m-%d %H:%M"), listed[:checkin_time]&.strftime("%Y-%m-%d %H:%M")
    assert_equal "checked in", RpmsRpc::Scheduling.patient_appointments(PATIENT).find { |a| a[:start_time] == start }[:status]

    visit = RpmsRpc::Scheduling.checkin_visit(dfn: PATIENT, clinic_ien: clinic, checkin_time: checkin)
    skip_tracked("openrpms#1342", "the check-in's visit is filed but BEHOENCX FETCH finds none") if visit.nil?
    assert_equal [ PATIENT, clinic ], visit.values_at(:patient_dfn, :location_ien)
  end
end
