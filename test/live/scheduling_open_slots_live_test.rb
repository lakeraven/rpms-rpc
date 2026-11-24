# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/scheduling_setup"

# A scheduler searches a clinic for open slots of its appointment length
# (rpms-ux S-SCH-04, rpms-rpc#948). Scheduling.open_slots computes them from
# stock reads (the BSDX blocks and appointments, and the clinic, holiday and
# access type files through DDR), as Windows Scheduling's Find Appointment
# does.
#
# The demo build's clinics, as the seed sets them: DEMO IHS CLINIC (20-minute
# appointments, display from 08:00, schedules on holidays, 90 days ahead) and
# DEMO SAME DAY (15 minutes, one day ahead, no holidays) have weekday blocks
# from the build date on; DEMO BEHAVIORAL HEALTH's blocks take one patient
# each; DEMO PRIMARY CARE (365 days, holidays) and DEMO DIABETES (180 days, no
# holidays) are where this spec files blocks of its own, on days past the
# seed's, and removes them again. DEMO PODIATRY is inactive. Dates are
# computed from today, so the spec holds on any later run of the same seed.
class SchedulingOpenSlotsLiveTest < LiveSpec::Test
  runs_as :scheduler
  writes!
  proves "S-SCH-04.1", "S-SCH-04.2", "S-SCH-04.3", "S-SCH-04.4", "S-SCH-04.5", "S-SCH-04.6"

  IHS = "DEMO IHS CLINIC"
  SAME_DAY = "DEMO SAME DAY"
  BH = "DEMO BEHAVIORAL HEALTH"
  PRIMARY = "DEMO PRIMARY CARE"
  DIABETES = "DEMO DIABETES"
  PODIATRY = "DEMO PODIATRY"
  PATIENT = 3 # MOUSE,MICKEY M
  CLINIC_CANCELLED = "13" # a clinic-type CANCELLATION REASON (#409.2)

  def sched = RpmsRpc::Scheduling
  def setup_api = RpmsRpc::SchedulingSetup

  def teardown
    @cleanup&.reverse_each(&:call)
    super
  end

  # S-SCH-04.1
  def test_every_slot_starts_in_a_block_on_a_day_in_range_and_ends_within_it
    first = Date.today
    last = first + 6
    slots = sched.open_slots(resource: IHS, start_date: first, end_date: last)
    blocks = sched.slot_schedule(resource: IHS, start_date: first, end_date: last).select { |b| b[:slots].positive? }

    refute_empty slots, "#{IHS} has weekday blocks from the build date on: is this the pinned build?"
    slots.each do |s|
      block = blocks.find { |b| b[:availability_id] == s[:availability_id] }
      refute_nil block, "#{s.inspect} names a block of the slot schedule"
      assert_includes first..last, s[:start_time].to_date
      assert_operator s[:start_time], :>=, block[:start_time]
      assert_operator s[:end_time], :<=, block[:end_time]
      assert_operator s[:start_time].hour, :>=, 8, "no earlier than the display start hour"
      assert_equal 20 * 60, s[:end_time] - s[:start_time], "the clinic's appointment length"
      assert_equal block[:slots], s[:open], "nothing is booked on #{IHS}"
    end
  end

  # S-SCH-04.1: an active appointment takes the block's one slot at its time.
  def test_a_booked_slot_is_not_open_until_the_appointment_is_cancelled
    first = Date.today + 1
    slot = sched.open_slots(resource: BH, start_date: first, end_date: first + 6).first
    flunk "#{BH} has blocks from the build date on: is this the pinned build?" unless slot

    day = slot[:start_time].to_date
    booked = sched.add_appointment(patient_dfn: PATIENT, resource: BH, start_time: slot[:start_time],
                                   end_time: slot[:end_time], length_minutes: 30, note: "live spec")
    assert booked && booked[:success], "BSDX ADD NEW APPOINTMENT: #{booked.inspect}"
    cancel = -> { sched.cancel_appointment(booked[:appointment_id], reason: CLINIC_CANCELLED, note: "live spec") }
    (@cleanup ||= []) << cancel

    starts = ->() { sched.open_slots(resource: BH, start_date: day, end_date: day).map { |s| s[:start_time] } }
    refute_includes starts.call, slot[:start_time], "the booked slot is taken"
    assert_includes starts.call, slot[:end_time], "the next slot is still open"

    assert cancel.call[:success]
    @cleanup.delete(cancel)
    assert_includes starts.call, slot[:start_time], "a cancelled appointment frees its slot"
  end

  # S-SCH-04.2
  def test_a_block_whose_access_type_prevents_access_has_no_slot
    day = free_weekday(PRIMARY, Date.today + 200)
    file_block(PRIMARY, day, 8, 10, prevent: true)
    file_block(PRIMARY, day, 13, 15, prevent: false)

    slots = sched.open_slots(resource: PRIMARY, start_date: day, end_date: day)
    refute_empty slots
    assert(slots.all? { |s| s[:start_time].hour >= 13 }, "only the block that allows access: #{starts(slots)}")
  end

  # S-SCH-04.3
  def test_a_holiday_has_no_slot_where_the_clinic_does_not_schedule_holidays
    day = free_weekday(DIABETES, Date.today + 150)
    file_block(PRIMARY, day, 9, 12, prevent: false)
    file_block(DIABETES, day, 9, 12, prevent: false)
    refute_empty sched.open_slots(resource: DIABETES, start_date: day, end_date: day), "before the holiday"

    assert setup_api.add_holiday(date: day, name: "LIVE SPEC OPEN SLOTS")[:success]
    (@cleanup ||= []) << -> { setup_api.remove_holiday(day) }

    assert_empty sched.open_slots(resource: DIABETES, start_date: day, end_date: day)
    refute_empty sched.open_slots(resource: PRIMARY, start_date: day, end_date: day), "#{PRIMARY} schedules on holidays"
  end

  # S-SCH-04.4
  def test_no_slot_past_the_maximum_days_for_future_booking_or_while_the_clinic_is_inactive
    today = Date.today
    blocks = sched.slot_schedule(resource: SAME_DAY, start_date: today, end_date: today + 14).select { |b| b[:slots].positive? }
    assert(blocks.any? { |b| b[:start_time].to_date > today + 1 }, "#{SAME_DAY} has blocks past tomorrow")

    days = sched.open_slots(resource: SAME_DAY, start_date: today, end_date: today + 14).map { |s| s[:start_time].to_date }.uniq
    assert(days.all? { |d| d <= today + 1 }, "#{SAME_DAY} books one day ahead: #{days}")

    day = free_weekday(PODIATRY, today + 30)
    file_block(PODIATRY, day, 9, 12, prevent: false)
    assert_empty sched.open_slots(resource: PODIATRY, start_date: day, end_date: day), "#{PODIATRY} is inactive"
  end

  # S-SCH-04.5
  def test_mornings_and_afternoons_split_the_slots_at_noon
    day_range = [ Date.today, Date.today + 6 ]
    all = sched.open_slots(resource: IHS, start_date: day_range[0], end_date: day_range[1])
    am = sched.open_slots(resource: IHS, start_date: day_range[0], end_date: day_range[1], ampm: "AM")
    pm = sched.open_slots(resource: IHS, start_date: day_range[0], end_date: day_range[1], ampm: "PM")

    refute_empty am
    refute_empty pm
    assert(am.all? { |s| s[:start_time].hour < 12 })
    assert(pm.all? { |s| s[:start_time].hour >= 12 })
    assert_equal starts(all), starts(am + pm).sort
  end

  # S-SCH-04.6
  def test_one_access_type_keeps_only_its_blocks
    first = Date.today
    general = access_type_id("DEMO GENERAL")
    same_day = access_type_id("DEMO SAME DAY")

    on_ihs = sched.open_slots(resource: IHS, start_date: first, end_date: first + 1)
    assert_equal starts(on_ihs), starts(sched.open_slots(resource: IHS, start_date: first, end_date: first + 1, access_type: general))
    assert_empty sched.open_slots(resource: IHS, start_date: first, end_date: first + 1, access_type: same_day)
    refute_empty sched.open_slots(resource: SAME_DAY, start_date: first, end_date: first + 1, access_type: same_day)
  end

  private

  def starts(slots) = slots.map { |s| s[:start_time] }

  def access_type_id(name)
    setup_api.access_types.find { |t| t[:name] == name }&.dig(:id) || flunk("no access type #{name}: is this the pinned build?")
  end

  # A weekday on or after +from+ where the resource has no block, so the spec owns it.
  def free_weekday(resource, from)
    day = from
    60.times do
      if !day.saturday? && !day.sunday? &&
         sched.slot_schedule(resource: resource, start_date: day, end_date: day).none? { |b| b[:availability_id].positive? }
        return day
      end

      day += 1
    end
    flunk "no free weekday on #{resource} within 60 days of #{from}"
  end

  # Files a two-slot block on the resource's day and removes it in teardown.
  def file_block(resource, day, from_hour, to_hour, prevent:)
    type = setup_api.access_types.find { |t| !t[:inactive] && t[:prevent_access] == prevent } ||
           flunk("no active access type with prevent_access #{prevent}")
    added = sched.add_availability(resource: resource, start_time: Time.new(day.year, day.month, day.day, from_hour),
                                   end_time: Time.new(day.year, day.month, day.day, to_hour), slots: 2,
                                   access_type_id: type[:id], note: "live spec")
    assert added && added[:success], "BSDX ADD NEW AVAILABILITY on #{resource}: #{added.inspect}"
    id = sched.resources.find { |r| r[:name] == resource }[:id]
    (@cleanup ||= []) << -> { sched.cancel_availability_by_date(resource_id: id, start_date: day, end_date: day) }
  end
end
