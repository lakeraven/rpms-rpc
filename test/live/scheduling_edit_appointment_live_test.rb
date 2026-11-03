# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/scheduling_setup"
require "rpms_rpc/api/ddr_fileman"

# Keeping an appointment's details current (rpms-ux S-SCH-09): its note and
# length through BSDX EDIT APPOINTMENT, the clinic's copy of the note (OTHER,
# #44.003 field 3) and a cancellation's remarks (#2.98 field 17) through DDR
# FILER, read back from FileMan.
class SchedulingEditAppointmentLiveTest < LiveSpec::Test
  writes!

  PATIENT = 3
  RESOURCE_NAME = "DEMO IHS CLINIC"

  def test_the_note_and_length_change_and_the_start_stays
    resource = demo_resource
    start = far_start
    id = book(start, note: "first note")

    begin
      edited = RpmsRpc::Scheduling.edit_appointment(id, note: "second note", length_minutes: 30)
      assert_equal({ success: true }, edited)
      assert_equal({ success: true }, RpmsRpc::SchedulingSetup.set_clinic_note(hospital_location_id: resource[:hospital_location_id],
                                                                                start_time: start, patient_dfn: PATIENT, note: "second note"))

      entry = clinic_entry(resource[:hospital_location_id], start)
      assert_equal [ "30", "second note" ], [ entry[:length], entry[:note] ], "#44.003 LENGTH OF APP'T and OTHER"
      listed = RpmsRpc::Scheduling.appointments(resource: RESOURCE_NAME, start_date: start.to_date, end_date: start.to_date).find { |a| a[:id] == id }
      assert_equal [ start, start + 1800, "second note" ], [ listed[:start_time], listed[:end_time], listed[:note].to_s.strip ], "BSDX keeps the start, moves the end and holds the note"
    ensure
      RpmsRpc::Scheduling.cancel_appointment(id, reason: "", type: "C", note: "live spec cleanup")
    end
  end

  def test_a_cancelled_appointment_s_remarks_are_filed_on_the_patient
    start = far_start
    id = book(start)
    RpmsRpc::Scheduling.cancel_appointment(id, reason: "", type: "C", note: "first remarks")

    assert_equal({ success: true }, RpmsRpc::SchedulingSetup.set_cancellation_remarks(patient_dfn: PATIENT, start_time: start, remarks: "corrected remarks"))
    got = client.with_context(RpmsRpc::SchedulingSetup::CONTEXT) do
      RpmsRpc::DdrFileman.gets_entry(file: "2.98", iens: "#{RpmsRpc::SchedulingSetup.send(:iens_time, start)},#{PATIENT},", fields: "3;17", flags: "I")
    end
    assert_equal [ "C", "corrected remarks" ], [ got[:fields]["3"][:internal], got[:fields]["17"][:internal] ]
  end

  def test_variable_length_reads_the_clinic_flag
    assert_includes [ true, false ], RpmsRpc::Scheduling.variable_length?(demo_resource[:hospital_location_id])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Scheduling.variable_length?(999_999) }
  end

  def test_an_unknown_appointment_is_refused
    reply = RpmsRpc::Scheduling.edit_appointment(999_999_999, note: "x")
    refute reply[:success], reply.inspect
  end

  private

  def demo_resource
    RpmsRpc::Scheduling.resources.find { |r| r[:name] == RESOURCE_NAME } || flunk("no BSDX resource #{RESOURCE_NAME}")
  end

  # A weekday far past anything else books, at a random quarter hour.
  def far_start
    day = Date.today + 500 + rand(90)
    day += 1 while day.saturday? || day.sunday?
    Time.new(day.year, day.month, day.day, 9 + rand(6), 15 * rand(4))
  end

  def book(start, note: nil)
    booked = RpmsRpc::Scheduling.add_appointment(patient_dfn: PATIENT, resource: RESOURCE_NAME, start_time: start,
                                                 end_time: start + 900, length_minutes: 15, note: note)
    assert booked && booked[:success], "BSDX ADD NEW APPOINTMENT: #{booked.inspect}"
    booked[:appointment_id]
  end

  def clinic_entry(clinic, start)
    at = RpmsRpc::SchedulingSetup.send(:iens_time, start)
    listing = client.with_context(RpmsRpc::SchedulingSetup::CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: "44.003", iens: ",#{at},#{clinic},", fields: "@;.01I;1;3", flags: "IP")
    end
    flunk "DDR LISTER #44.003 ,#{at},#{clinic},: #{listing.inspect}" if listing.nil? || listing[:error]
    entry = listing[:entries].find { |e| e[:pieces].first.to_i == PATIENT } || flunk("no #44.003 entry for #{PATIENT} at #{at}")
    { length: entry[:pieces][1].to_s, note: entry[:pieces][2].to_s }
  end
end
