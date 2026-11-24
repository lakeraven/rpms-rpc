# frozen_string_literal: true

require "rpms_rpc/api/scheduling"

# Scheduling.open_slots run as the scheduler on the demo build (rpms-rpc#948):
# every read it makes (BSDX RESOURCES, SchedulingSetup.clinic_rules, the #44
# appointment length, BSDX CREATE ASGND SLOT SCHED, BSDX CREATE APPT SCHEDULE,
# the holidays and the access types), kept so the slot rules replay against
# what the build answered. The dates are fixed and today: is the build date.
TODAY = Date.new(2026, 11, 24)
CAPTURE = {
  rpc: "BSDX CREATE ASGND SLOT SCHED", entry_point: "CASSCH^BSDX04",
  signed_on_as: "PROFILE,SCHED (PSCH123, a published demo pair)",
  access: "PSCH123", verify: "PSCH123!!", context: "BSDXRPC",
  note: "The demo build's clinics as seeded: DEMO IHS CLINIC schedules on holidays (2026-11-26 is Thanksgiving " \
        "in HOLIDAY), DEMO SAME DAY books one day ahead, DEMO BEHAVIORAL HEALTH's blocks take one patient. " \
        "Nothing is booked.",
  calls: [],
  flows: {
    "ihs_over_thanksgiving" => {
      about: "open_slots on DEMO IHS CLINIC, 2026-11-25 to 2026-11-26, today 2026-11-24",
      run: -> { RpmsRpc::Scheduling.open_slots(resource: "DEMO IHS CLINIC", start_date: TODAY + 1, end_date: TODAY + 2, today: TODAY) }
    },
    "same_day_week" => {
      about: "open_slots on DEMO SAME DAY, 2026-11-24 to 2026-11-30, today 2026-11-24",
      run: -> { RpmsRpc::Scheduling.open_slots(resource: "DEMO SAME DAY", start_date: TODAY, end_date: TODAY + 6, today: TODAY) }
    },
    "bh_afternoon" => {
      about: "open_slots on DEMO BEHAVIORAL HEALTH, 2026-11-25, afternoons, today 2026-11-24",
      run: -> { RpmsRpc::Scheduling.open_slots(resource: "DEMO BEHAVIORAL HEALTH", start_date: TODAY + 1, end_date: TODAY + 1, ampm: "PM", today: TODAY) }
    }
  }
}.freeze
