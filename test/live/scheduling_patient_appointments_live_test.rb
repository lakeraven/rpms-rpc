# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/scheduling"

# Scheduling.patient_appointments (BSDX PATIENT APPT DISPLAY) on a real build
# (rpms-ux S-SCH-05.6): an appointment booked for a patient is listed with its
# clinic, time, status and who made it, and the patient's address and phone are
# not returned. Books one appointment on a disposable container.
class SchedulingPatientAppointmentsLiveTest < LiveSpec::Test
  writes!

  PATIENT = 3 # MOUSE,MICKEY M, on every demo build
  CLINIC = "DEMO IHS CLINIC"

  def book_somewhere_open
    40.times do
      day = Date.today + 21 + rand(21)
      day += 1 while day.saturday? || day.sunday?
      start = Time.new(day.year, day.month, day.day, 13 + rand(4), [ 0, 15, 30, 45 ].sample)
      reply = RpmsRpc::Scheduling.add_appointment(patient_dfn: PATIENT, resource: CLINIC, start_time: start,
                                                  end_time: start + 900, length_minutes: 15)
      return start if reply && reply[:success]
    end
    flunk "no time three to six weeks out took a booking for DFN #{PATIENT} on #{CLINIC}"
  end

  def test_a_booked_appointment_is_listed_with_its_clinic_status_and_who_made_it
    start = book_somewhere_open

    listed = RpmsRpc::Scheduling.patient_appointments(PATIENT)
    mine = listed.find { |a| a[:start_time] == start && a[:clinic] == CLINIC }

    assert mine, "the appointment booked at #{start} is listed"
    assert_equal "scheduled", mine[:status]
    assert_includes %w[SCHED WALK-IN], mine[:type]
    assert_kind_of Integer, mine[:resource_id]
    refute_nil mine[:made_by], "who made it is recorded"
    assert(listed.all? { |a| (a.keys & %i[street city state zip homephone name dob sex hrn]).empty? })
  end
end
