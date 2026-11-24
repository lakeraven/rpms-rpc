# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/scheduling"
require_relative "../captured_replies"

# Scheduling.open_slots (rpms-rpc#948, rpms-ux S-SCH-04) replays the reads it
# made as PROFILE,SCHED on bcer-9.0-20261124-60d39b6-ydb
# (test/fixtures/captured_replies/bsdx-open-slots.yml): the build's own
# blocks, clinic rules, holidays and access types, with nothing booked. The
# live spec, test/live/scheduling_open_slots_live_test.rb, proves each rule
# against a container, booking and filing what it needs.
class SchedulingOpenSlotsTest < Minitest::Test
  SLUG = "bsdx-open-slots"
  TODAY = Date.new(2026, 11, 24)

  def teardown = RpmsRpc.reset!

  def replay(flow)
    @client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(SLUG, flow))
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| c[:rpc] }

  def at(day, hour, minute = 0) = Time.new(day.year, day.month, day.day, hour, minute, 0)

  def test_slots_step_by_the_clinics_length_through_each_block_and_a_holiday_is_kept_where_the_clinic_schedules_it
    replay("ihs_over_thanksgiving")
    slots = RpmsRpc::Scheduling.open_slots(resource: "DEMO IHS CLINIC", start_date: TODAY + 1, end_date: TODAY + 2, today: TODAY)

    thanksgiving = TODAY + 2
    assert_equal [ TODAY + 1, thanksgiving ], slots.map { |s| s[:start_time].to_date }.uniq
    day = slots.select { |s| s[:start_time].to_date == thanksgiving }
    assert_equal 27, day.size, "08:00 to 17:00 in 20-minute slots"
    assert_equal({ start_time: at(thanksgiving, 8), end_time: at(thanksgiving, 8, 20), access_type_id: 1,
                   availability_id: day.first[:availability_id], open: 4 }, day.first)
    assert_equal at(thanksgiving, 16, 40), day.last[:start_time]
    assert_equal [ "BSDX RESOURCES", "DDR GETS ENTRY DATA", "DDR GETS ENTRY DATA", "BSDX CREATE ASGND SLOT SCHED",
                   "BSDX CREATE APPT SCHEDULE", "DDR LISTER", "DDR LISTER" ], sent
  end

  # Each BSDX read runs under BSDXRPC and each DDR read under CIAV VUECENTRIC,
  # the options that register them.
  def test_each_read_runs_under_the_option_that_registers_it
    replay("ihs_over_thanksgiving")
    RpmsRpc::Scheduling.open_slots(resource: "DEMO IHS CLINIC", start_date: TODAY + 1, end_date: TODAY + 2, today: TODAY)

    bound = nil
    under = @client.calls.filter_map do |c|
      if c[:rpc] == :create_context
        bound = c[:params].first
        next
      end

      [ c[:rpc], bound ]
    end
    assert_equal 7, under.size
    under.each do |rpc, option|
      assert_equal rpc.start_with?("BSDX") ? "BSDXRPC" : "CIAV VUECENTRIC", option, "#{rpc} ran under #{option.inspect}"
    end
  end

  def test_no_slot_past_the_clinics_maximum_days_for_future_booking
    replay("same_day_week")
    slots = RpmsRpc::Scheduling.open_slots(resource: "DEMO SAME DAY", start_date: TODAY, end_date: TODAY + 6, today: TODAY)

    assert_equal [ TODAY, TODAY + 1 ], slots.map { |s| s[:start_time].to_date }.uniq, "DEMO SAME DAY books one day ahead"
    assert(slots.all? { |s| s[:end_time] - s[:start_time] == 15 * 60 })
  end

  def test_afternoons_are_the_slots_from_noon
    replay("bh_afternoon")
    slots = RpmsRpc::Scheduling.open_slots(resource: "DEMO BEHAVIORAL HEALTH", start_date: TODAY + 1, end_date: TODAY + 1,
                                           ampm: "PM", today: TODAY)

    assert_equal (13..16).flat_map { |h| [ at(TODAY + 1, h), at(TODAY + 1, h, 30) ] }, slots.map { |s| s[:start_time] }
    assert(slots.all? { |s| s[:open] == 1 })
  end

  def test_an_unknown_ampm_is_refused_before_any_read
    replay("bh_afternoon")

    assert_raises(ArgumentError) { RpmsRpc::Scheduling.open_slots(resource: "DEMO BEHAVIORAL HEALTH", start_date: TODAY, end_date: TODAY, ampm: "NOON") }
    assert_empty sent
  end
end
