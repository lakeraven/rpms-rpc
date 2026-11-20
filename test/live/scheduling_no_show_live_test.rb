# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/scheduling"

# Scheduling.mark_no_show over BSDX NOSHOW (NOSHOW^BSDX31): an appointment
# booked on a past weekday is marked a no-show, read back as one from the
# resource's appointment list (BSDX CREATE APPT SCHEDULE's NOSHOW column),
# then cleared and read back again. The reply's first piece is a success flag
# with the polarity inverted from the other BSDX writes (1 success).
class SchedulingNoShowLiveTest < LiveSpec::Test
  runs_as :scheduler
  writes!

  PATIENT = 3
  CLINIC_NAME = "DEMO IHS CLINIC"
  RESOURCE_NAME = "LIVE SPEC NO SHOW"

  def test_mark_then_clear_a_no_show_and_read_each_back
    start, id = book_in_the_past
    refute appointment(start, id)[:no_show], "a fresh booking is not a no-show"

    assert_equal({ success: true }, RpmsRpc::Scheduling.mark_no_show(id))
    assert appointment(start, id)[:no_show], "appointment #{id} is not read back as a no-show"

    assert_equal({ success: true }, RpmsRpc::Scheduling.mark_no_show(id, no_show: false))
    refute appointment(start, id)[:no_show], "appointment #{id} is still a no-show after it was cleared"
  end

  def test_an_appointment_not_on_file_is_refused_with_the_routines_reason
    result = RpmsRpc::Scheduling.mark_no_show("999999999")
    refute_nil result, "BSDX NOSHOW gave no reply"
    refute result[:success], "a no-show on an appointment not on file answered success"
    refute_empty result[:error].to_s, "the refusal carries the routine's reason"
  end

  private

  def appointment(start, id)
    RpmsRpc::Scheduling.appointments(resource: RESOURCE_NAME, start_date: start.to_date, end_date: start.to_date).find { |a| a[:id] == id } ||
      flunk("appointment #{id} is not on #{RESOURCE_NAME}")
  end

  def clinic
    @clinic ||= RpmsRpc::Scheduling.hospital_locations.find { |h| h[:location] == CLINIC_NAME } || flunk("no hospital location #{CLINIC_NAME}")
  end

  def ensure_resource!
    return if RpmsRpc::Scheduling.resources.any? { |r| r[:name] == RESOURCE_NAME }

    reply = client.with_context(RpmsRpc::Scheduling::CONTEXT) do
      client.call_rpc("BSDX ADD/EDIT RESOURCE", "0|#{RESOURCE_NAME}|NO|#{clinic[:location_ien]}|15")
    end
    flunk "BSDX ADD/EDIT RESOURCE refused #{RESOURCE_NAME}: #{reply.inspect}" if Array(reply).any? { |l| l.match?(/BSDX14:/i) }
  end

  def book_in_the_past
    ensure_resource!
    40.times do
      day = Date.today - 3 - rand(60)
      day -= 1 while day.saturday? || day.sunday?
      start = Time.new(day.year, day.month, day.day, 8 + rand(8), [ 0, 15, 30 ].sample)
      reply = RpmsRpc::Scheduling.add_appointment(patient_dfn: PATIENT, resource: RESOURCE_NAME, start_time: start,
                                                  end_time: start + 900, length_minutes: 15)
      return [ start, reply[:appointment_id] ] if reply && reply[:success]
    end
    flunk "no past weekday took a booking for DFN #{PATIENT} on #{RESOURCE_NAME}"
  end
end
