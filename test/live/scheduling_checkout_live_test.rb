# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/scheduling_setup"
require "rpms_rpc/api/ddr_fileman"

# The patient's day after booking, on the clinic's own record: check in, undo
# the check-in, check in again, check out and undo the check-out, each read
# back from HOSPITAL LOCATION (#44.003) with DDR LISTER (rpms-ux S-SCH-03.9,
# S-SCH-07.1, 07.2, 07.3, 07.6). The appointment is booked on a weekday in the
# past, so every time sent is behind the server's clock whatever its zone.
class SchedulingCheckoutLiveTest < LiveSpec::Test
  writes!

  PATIENT = 3
  CLINIC_NAME = "DEMO IHS CLINIC"
  RESOURCE_NAME = "LIVE SPEC CHECKOUT"
  # #44.003 PATIENT (the appointment on the clinic): 309 CHECKED-IN, 302 CHECK
  # IN USER, 303 CHECKED OUT, 304 CHECK OUT USER.
  FIELDS = "@;.01I;309I;302I;303I;304I"

  def test_check_in_undo_check_in_check_out_and_undo_check_out
    start, id = book_in_the_past
    checkin = start + 600

    assert RpmsRpc::Scheduling.checkin_appointment(id, checkin_time: checkin)[:success]
    assert_equal [ fm(checkin), duz, "", "" ], on_clinic(start)

    assert RpmsRpc::Scheduling.cancel_checkin(id)[:success]
    assert_equal [ "", "", "", "" ], on_clinic(start), "the undo clears the check-in time and user"
    assert_nil appointment(start, id)[:checkin_time]

    refused = RpmsRpc::Scheduling.checkout_appointment(id, patient_dfn: PATIENT, appointment_time: start, checkout_time: start + 1800)
    refute refused[:success], "an appointment not checked in is not checked out"
    assert_match(/not checked in/i, refused[:error])

    assert RpmsRpc::Scheduling.checkin_appointment(id, checkin_time: checkin)[:success]
    early = RpmsRpc::Scheduling.checkout_appointment(id, patient_dfn: PATIENT, appointment_time: start, checkout_time: checkin)
    refute early[:success], "a check-out not after the check-in is refused"
    assert_match(/after the Check In time/, early[:error])
    assert_equal "", on_clinic(start)[2], "nothing filed for the refused check-out"

    checkout = start + 1800
    assert RpmsRpc::Scheduling.checkout_appointment(id, patient_dfn: PATIENT, appointment_time: start, checkout_time: checkout)[:success]
    assert_equal [ fm(checkin), duz, fm(checkout), duz ], on_clinic(start)
    assert_equal checkout.strftime("%Y-%m-%d %H:%M"), appointment(start, id)[:checkout_time].strftime("%Y-%m-%d %H:%M")

    assert RpmsRpc::Scheduling.cancel_checkout(id)[:success]
    assert_equal [ fm(checkin), duz, "", "" ], on_clinic(start), "checked in again, with no check-out"
    again = RpmsRpc::Scheduling.cancel_checkout(id)
    refute again[:success]
    assert_equal "Appointment is not Checked Out.", again[:error]
  end

  def test_the_clinic_stops_hold_the_clinics_own_stop
    hloc = clinic[:location_ien]
    stop = RpmsRpc::SchedulingSetup.clinic_stop(hloc)
    stops = RpmsRpc::SchedulingSetup.clinic_stops

    assert stop, "#{CLINIC_NAME} has a STOP CODE NUMBER"
    assert_includes stops.map { |s| s[:id] }, stop
    assert_operator stops.size, :>, 100, "the whole of CLINIC STOP, read on past one page"
    assert_equal stops.map { |s| s[:id] }.uniq, stops.map { |s| s[:id] }
  end

  private

  def fm(time) = RpmsRpc::FilemanDateParser.to_fileman(time).sub(/0+\z/, "").chomp(".")

  def duz = client.duz.to_s

  def appointment(start, id)
    RpmsRpc::Scheduling.appointments(resource: RESOURCE_NAME, start_date: start.to_date, end_date: start.to_date).find { |a| a[:id] == id } ||
      flunk("appointment #{id} is not on #{RESOURCE_NAME}")
  end

  # [check-in time, check-in user, check-out time, check-out user] of the
  # patient's appointment at start on the clinic, as FileMan holds them.
  def on_clinic(start)
    listed = client.with_context(RpmsRpc::SchedulingSetup::CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: "44.003", iens: ",#{fm(start)},#{clinic[:location_ien]},", fields: FIELDS, flags: "IP", max: "50")
    end
    flunk "DDR LISTER on #44.003 gave no reply" if listed.nil?
    flunk "DDR LISTER on #44.003 refused: #{listed.inspect}" if listed[:error]
    row = listed[:entries].find { |e| e[:pieces][0] == PATIENT.to_s } || flunk("DFN #{PATIENT} is not on #{CLINIC_NAME} at #{start}")
    row[:pieces][1, 4].map { |v| v.to_s.sub(/0+\z/, "").chomp(".") }
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
