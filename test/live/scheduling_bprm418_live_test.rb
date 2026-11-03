# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/scheduling_setup"

# rpms-rpc#418 live writes: synthetic holiday add/list/remove. Undo check-in
# moved to rpms-rpc#570.
class SchedulingBprm418LiveTest < LiveSpec::Test
  writes!

  HOLIDAY_DATE = Date.new(2032, 11, 11)
  HOLIDAY_NAME = "LIVESPEC-418 HOLIDAY"

  def test_add_holiday_lists_in_holidays_and_remove_clears_it
    chosen_date = nil
    60.times do |offset|
      candidate = HOLIDAY_DATE + offset
      range = (candidate - 1)..(candidate + 1)
      listed = RpmsRpc::SchedulingSetup.holidays(start_date: range.begin, end_date: range.end) || []
      next if listed.any? { |h| h[:date] == candidate }

      chosen_date = candidate
      break
    end
    flunk "no holiday-free date within 60 days of #{HOLIDAY_DATE}" unless chosen_date

    assert RpmsRpc::SchedulingSetup.add_holiday(date: chosen_date, name: HOLIDAY_NAME)[:success]
    @restore = -> { RpmsRpc::SchedulingSetup.remove_holiday(chosen_date) }

    range = (chosen_date - 1)..(chosen_date + 1)
    listed = RpmsRpc::SchedulingSetup.holidays(start_date: range.begin, end_date: range.end)
    row = listed.find { |h| h[:date] == chosen_date }
    assert row, "holiday not listed: #{listed.inspect}"
    assert_equal HOLIDAY_NAME, row[:name]

    assert RpmsRpc::SchedulingSetup.remove_holiday(chosen_date)[:success]
    @restore = nil
    assert_nil RpmsRpc::SchedulingSetup.holidays(start_date: range.begin, end_date: range.end)
      .find { |h| h[:date] == chosen_date }
  end

  def teardown
    failures = []
    if client && @restore
      begin
        result = @restore.call
        failures << "restore failed: #{result.inspect}" unless result.is_a?(Hash) && result[:success] == true
      rescue StandardError => e
        failures << e.full_message(highlight: false).strip
      end
    end
  ensure
    super
    flunk("teardown cleanup failures:\n#{failures.join("\n\n")}") unless failures.empty?
  end
end
