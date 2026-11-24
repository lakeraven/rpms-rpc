# frozen_string_literal: true

require "date"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/encounter"

# ORWPT APPTLST, as Encounter.for_patient reads it (APPTLST^ORWPT), for a
# patient with an appointment in its window (30 days back to tomorrow). Setup
# books MOUSE,MICKEY M (DFN 3) on DEMO IHS CLINIC tomorrow at 13:15 as the
# scheduler test role; the read runs as the provider test role. rpms-rpc#221.
APPT_DAY = Date.today + 1
APPT_AT = Time.new(APPT_DAY.year, APPT_DAY.month, APPT_DAY.day, 13, 15)

CAPTURE = {
  rpc: "ORWPT APPTLST", entry_point: "APPTLST^ORWPT",
  signed_on_as: "PROFILE,SCHED (PSCH123, the scheduler test role's published demo pair) for setup",
  access: "PSCH123", verify: "PSCH123!!",
  personas: {
    provider: { signed_on_as: "PROFILE,MD (PMD123, the provider test role's published demo pair)", access: "PMD123", verify: "PMD123!!" }
  },
  note: "Run on a fresh throwaway container. Setup books DFN 3 on DEMO IHS CLINIC at #{APPT_AT.strftime('%H:%M')} " \
        "the day after the capture; the read files nothing.",
  setup: lambda { |session|
    RpmsRpc.configure { |cfg| cfg.client = session }
    booked = RpmsRpc::Scheduling.add_appointment(patient_dfn: 3, resource: "DEMO IHS CLINIC", start_time: APPT_AT,
                                                 end_time: APPT_AT + 900, length_minutes: 15)
    abort "setup: could not book DFN 3 at #{APPT_AT}: #{booked.inspect}" unless booked && booked[:success]
    RpmsRpc.reset!
    {}
  },
  flows: {
    "for_patient_booked" => { as: :provider, about: "Encounter.for_patient of DFN 3, booked tomorrow at 13:15",
                              run: -> { RpmsRpc::Encounter.for_patient(3) } }
  }
}.freeze
