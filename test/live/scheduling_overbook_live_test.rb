# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/scheduling_setup"
require "rpms_rpc/api/ddr_fileman"

# Overbooking (rpms-ux S-SCH-01.9 to 01.11, lakeraven-ehr#603): whether one
# more overbook is allowed (BSDX OVERBOOK), whether the user holds the master
# overbook right (BSDX RESOURCE USER .06), and marking a booking as an
# overbook in OVERBOOK (#44.003 field 9), read back from FileMan.
class SchedulingOverbookLiveTest < LiveSpec::Test
  writes!

  PATIENT = 3
  RESOURCE_NAME = "DEMO IHS CLINIC"

  def test_overbook_allowed_answers_yes_or_no_for_the_resource_and_day
    resource = demo_resource
    answer = RpmsRpc::Scheduling.overbook_allowed(hospital_location_id: resource[:hospital_location_id],
                                                  start_time: Time.new(far_day.year, far_day.month, far_day.day, 9),
                                                  resource_id: resource[:id])

    assert_includes [ true, false ], answer
  end

  def test_overbook_allowed_raises_on_a_clinic_that_is_not_on_file
    assert_raises(RpmsRpc::Client::RpcError) do
      RpmsRpc::Scheduling.overbook_allowed(hospital_location_id: 999_999, start_time: Time.new(2027, 1, 4, 9), resource_id: demo_resource[:id])
    end
  end

  def test_master_overbook_reads_the_resource_user_entry
    resource = demo_resource
    duz = client.duz.to_i
    assert duz.positive?, "the session has a DUZ"

    assert_includes [ true, false ], RpmsRpc::SchedulingSetup.master_overbook?(resource_id: resource[:id], duz: duz)
    refute RpmsRpc::SchedulingSetup.master_overbook?(resource_id: resource[:id], duz: 999_999), "a user with no entry holds no right"
  end

  def test_a_booking_is_marked_an_overbook_in_44_003_field_9
    resource = demo_resource
    clinic = resource[:hospital_location_id]
    day = far_day
    start = Time.new(day.year, day.month, day.day, 9, 15 * rand(4))
    booked = RpmsRpc::Scheduling.add_appointment(patient_dfn: PATIENT, resource: RESOURCE_NAME, start_time: start,
                                                 end_time: start + 900, length_minutes: 15)
    assert booked && booked[:success], "BSDX ADD NEW APPOINTMENT: #{booked.inspect}"

    begin
      assert_equal "", overbook_mark(clinic, start), "BSDX ADD NEW APPOINTMENT leaves OVERBOOK empty"

      assert_equal({ success: true }, RpmsRpc::SchedulingSetup.mark_overbook(hospital_location_id: clinic, start_time: start, patient_dfn: PATIENT))
      assert_equal "O", overbook_mark(clinic, start), "#44.003 field 9 holds O"
      again = RpmsRpc::SchedulingSetup.mark_overbook(hospital_location_id: clinic, start_time: start, patient_dfn: PATIENT)
      assert_equal({ success: true }, again, "marking again is harmless")

      other = RpmsRpc::SchedulingSetup.mark_overbook(hospital_location_id: clinic, start_time: start, patient_dfn: 999_999)
      refute other[:success], "no appointment for that patient then: #{other.inspect}"
    ensure
      RpmsRpc::Scheduling.cancel_appointment(booked[:appointment_id], reason: "", type: "C", note: "live spec cleanup")
    end
  end

  def test_s_sch_05_3_an_overbook_and_who_cancelled_read_back
    resource = demo_resource
    clinic = resource[:hospital_location_id]
    day = far_day
    start = Time.new(day.year, day.month, day.day, 10, 15 * rand(4))
    booked = RpmsRpc::Scheduling.add_appointment(patient_dfn: PATIENT, resource: RESOURCE_NAME, start_time: start,
                                                 end_time: start + 900, length_minutes: 15)
    assert booked && booked[:success], "BSDX ADD NEW APPOINTMENT: #{booked.inspect}"
    where = { hospital_location_id: clinic, start_time: start, patient_dfn: PATIENT }

    refute RpmsRpc::SchedulingSetup.overbook?(**where)
    assert RpmsRpc::SchedulingSetup.mark_overbook(**where)[:success]
    assert RpmsRpc::SchedulingSetup.overbook?(**where)
    refute RpmsRpc::SchedulingSetup.overbook?(**where, patient_dfn: 999_999)
    assert_nil RpmsRpc::SchedulingSetup.cancelled_by(start_time: start, patient_dfn: PATIENT)

    RpmsRpc::Scheduling.cancel_appointment(booked[:appointment_id], reason: "", type: "PC", note: "live spec")
    assert_equal :patient, RpmsRpc::SchedulingSetup.cancelled_by(start_time: start, patient_dfn: PATIENT)

    later = start + 3600
    second = RpmsRpc::Scheduling.add_appointment(patient_dfn: PATIENT, resource: RESOURCE_NAME, start_time: later,
                                                 end_time: later + 900, length_minutes: 15)
    assert second && second[:success], "BSDX ADD NEW APPOINTMENT: #{second.inspect}"
    RpmsRpc::Scheduling.cancel_appointment(second[:appointment_id], reason: "", type: "C", note: "live spec")
    assert_equal :clinic, RpmsRpc::SchedulingSetup.cancelled_by(start_time: later, patient_dfn: PATIENT)
  end

  private

  def demo_resource
    RpmsRpc::Scheduling.resources.find { |r| r[:name] == RESOURCE_NAME } || flunk("no BSDX resource #{RESOURCE_NAME}")
  end

  # A weekday far past anything else books, so the spec owns its times.
  def far_day
    @far_day ||= begin
      day = Date.today + 500 + rand(60)
      day += 1 while day.saturday? || day.sunday?
      day
    end
  end

  def overbook_mark(clinic, start)
    at = RpmsRpc::SchedulingSetup.send(:iens_time, start)
    listing = client.with_context(RpmsRpc::SchedulingSetup::CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: "44.003", iens: ",#{at},#{clinic},", fields: "@;.01I;9I", flags: "IP")
    end
    flunk "DDR LISTER #44.003 ,#{at},#{clinic},: #{listing.inspect}" if listing.nil? || listing[:error]
    entry = listing[:entries].find { |e| e[:pieces].first.to_i == PATIENT } || flunk("no #44.003 entry for #{PATIENT} at #{at}")
    entry[:pieces][1].to_s
  end
end
