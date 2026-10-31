# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/scheduling_setup"
require "rpms_rpc/api/ddr_fileman"

# rpms-rpc#418 live writes: synthetic holiday add/list/remove and undo check-in.
class SchedulingBprm418LiveTest < LiveSpec::Test
  writes!

  PATIENT = 3
  CLINIC = "DEMO IHS CLINIC"
  HOLIDAY_DATE = Date.new(2032, 11, 11)
  HOLIDAY_NAME = "LIVESPEC-418 HOLIDAY"

  def test_add_holiday_lists_in_holidays_and_remove_clears_it
    range = (HOLIDAY_DATE - 1)..(HOLIDAY_DATE + 1)
    @restore = -> { RpmsRpc::SchedulingSetup.remove_holiday(HOLIDAY_DATE) }

    assert RpmsRpc::SchedulingSetup.add_holiday(date: HOLIDAY_DATE, name: HOLIDAY_NAME)[:success]

    listed = RpmsRpc::SchedulingSetup.holidays(start_date: range.begin, end_date: range.end)
    row = listed.find { |h| h[:date] == HOLIDAY_DATE }
    assert row, "holiday not listed: #{listed.inspect}"
    assert_equal HOLIDAY_NAME, row[:name]

    assert RpmsRpc::SchedulingSetup.remove_holiday(HOLIDAY_DATE)[:success]
    assert_nil RpmsRpc::SchedulingSetup.holidays(start_date: range.begin, end_date: range.end)
      .find { |h| h[:date] == HOLIDAY_DATE }
  end

  def test_undo_checkin_clears_the_check_in_time_on_the_appointment
    start, appt_ien = book_somewhere_open
    refute_nil appt_ien, "booking did not return an appointment id"

    checkin = RpmsRpc::Scheduling.checkin_appointment(appt_ien, checkin_time: start)
    assert checkin && checkin[:success], "check-in failed: #{checkin.inspect}"
    assert check_in_time(appt_ien), "check-in time not stored"

    undo = RpmsRpc::Scheduling.undo_checkin(appt_ien)
    assert undo && undo[:success], "undo check-in failed: #{undo.inspect}"
    assert_nil check_in_time(appt_ien), "9002018.4 .03 should be empty after undo"
  end

  def teardown
    @restore&.call if client
  ensure
    super
  end

  private

  def book_somewhere_open
    40.times do
      day = Date.today + 21 + rand(21)
      day += 1 while day.saturday? || day.sunday?
      start = Time.new(day.year, day.month, day.day, 13 + rand(4), [ 0, 15, 30, 45 ].sample)
      reply = RpmsRpc::Scheduling.add_appointment(patient_dfn: PATIENT, resource: CLINIC, start_time: start,
                                                  end_time: start + 900, length_minutes: 15)
      return [ start, reply[:appointment_id] ] if reply && reply[:success]
    end
    flunk "no booking slot for undo check-in live spec"
  end

  def check_in_time(appointment_ien)
    got = RpmsRpc::DdrFileman.gets_entry(file: "9002018.4", iens: "#{appointment_ien},", fields: ".03", flags: "I")
    refute_nil got, "DDR GETS ENTRY DATA gave no reply for 9002018.4 #{appointment_ien}"
    refute got[:error], "read failed for 9002018.4 #{appointment_ien}: #{got.inspect}"

    internal = got[:fields].dig(".03", :internal).to_s
    internal.empty? ? nil : internal
  end
end
