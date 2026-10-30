# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/scheduling_setup"
require "rpms_rpc/api/ddr_fileman"

# SchedulingSetup on a real build: the access types, holidays and a clinic's
# booking rules that decide where an appointment may go (rpms-ux S-SCH-04.2,
# 04.3, 04.4, 04.6). The flags are written first, so each is read back from a
# stored value and not only from the demo's empty ones: an access type that
# prevents access goes in through the scheduling client's own BSDX ADD/EDIT
# ACCESS TYPE, and the clinic's #44 fields through DDR FILER, put back after.
class SchedulingSetupLiveTest < LiveSpec::Test
  writes!

  PREVENTS = "LIVE SPEC PREVENTS"
  CLINIC = "DEMO IHS CLINIC"

  def test_an_access_type_that_prevents_access_reads_as_preventing
    before = RpmsRpc::SchedulingSetup.access_types.find { |t| t[:name] == PREVENTS }
    reply = client.with_context(RpmsRpc::Scheduling::CONTEXT) do
      client.call_rpc("BSDX ADD/EDIT ACCESS TYPE", "#{before ? before[:id] : 0}|#{PREVENTS}|NO|||||YES")
    end
    refute_match(/BSDX14:/, Array(reply).join, "BSDX ADD/EDIT ACCESS TYPE refused: #{reply.inspect}")

    types = RpmsRpc::SchedulingSetup.access_types
    prevents = types.find { |t| t[:name] == PREVENTS }
    assert prevents, "the access type just filed is listed: #{types.inspect}"
    assert prevents[:prevent_access]
    refute prevents[:inactive]
    assert(types.any? { |t| !t[:prevent_access] }, "the build's own access types do not prevent access: #{types.inspect}")
    assert_equal types.map { |t| t[:name] }.sort, types.map { |t| t[:name] }
  end

  def test_holidays_are_listed_by_date_with_both_ends_of_the_range_included
    all = RpmsRpc::SchedulingSetup.holidays(start_date: Date.today - 400, end_date: Date.today + 400)
    refute_empty all, "the build has no HOLIDAY (#40.5) entry within 400 days of today"
    assert_equal all.map { |h| h[:date] }.sort, all.map { |h| h[:date] }
    all.each do |h|
      assert_kind_of Date, h[:date]
      refute_empty h[:name].to_s
    end

    first, second = all.first(2)
    assert_equal [ first ], RpmsRpc::SchedulingSetup.holidays(start_date: first[:date], end_date: first[:date])
    if second
      assert_equal [ first, second ], RpmsRpc::SchedulingSetup.holidays(start_date: first[:date], end_date: second[:date])
      assert_equal [], RpmsRpc::SchedulingSetup.holidays(start_date: first[:date] + 1, end_date: second[:date] - 1)
    end
  end

  def test_a_clinics_booking_rules_read_back_as_filed
    resource = RpmsRpc::Scheduling.resources.find { |r| r[:name] == CLINIC }
    assert resource, "the persona has no #{CLINIC} resource"
    ien = resource[:hospital_location_id]
    original = RpmsRpc::SchedulingSetup.clinic_rules(ien)
    inactive_on = Date.today + 200
    reactive_on = Date.today + 230

    begin
      file(ien, "1918.5" => "@", "2002" => "45", "2505" => fm(inactive_on), "2506" => fm(reactive_on), "1914" => "9")
      rules = RpmsRpc::SchedulingSetup.clinic_rules(ien)
      assert_equal({ id: ien, display_begins: 9, schedule_on_holidays: false, max_future_days: 45, prohibit_access: false,
                     inactivate_date: inactive_on, reactivate_date: reactive_on }, rules)

      file(ien, "1918.5" => "Y")
      assert RpmsRpc::SchedulingSetup.clinic_rules(ien)[:schedule_on_holidays]
    ensure
      file(ien, "1918.5" => original[:schedule_on_holidays] ? "Y" : "@",
                "2002" => original[:max_future_days]&.to_s || "@",
                "2505" => original[:inactivate_date] ? fm(original[:inactivate_date]) : "@",
                "2506" => original[:reactivate_date] ? fm(original[:reactivate_date]) : "@",
                "1914" => original[:display_begins]&.to_s || "@")
    end
    assert_equal original, RpmsRpc::SchedulingSetup.clinic_rules(ien), "the clinic's fields are put back"
  end

  def test_a_clinic_that_is_not_a_number_is_nil
    [ nil, "", "0", "abc", "-3" ].each { |bad| assert_nil RpmsRpc::SchedulingSetup.clinic_rules(bad), bad.inspect }
  end

  private

  def fm(date) = RpmsRpc::FilemanDateParser.to_fileman(date)

  def file(ien, values)
    rows = values.map { |field, value| { file: 44, field: field, iens: "#{ien},", value: value } }
    got = client.with_context(RpmsRpc::SchedulingSetup::CONTEXT) { RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: rows) }
    assert got && got[:success], "DDR FILER on #44 #{ien}: #{got.inspect}"
  end
end
