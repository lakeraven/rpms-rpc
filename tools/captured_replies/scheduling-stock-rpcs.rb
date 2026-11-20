# frozen_string_literal: true

require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/ddr_fileman"

# The conversations RpmsRpc::Scheduling's check-in visit read, check-in and
# check-out refusals have with the build, recorded as flows as the scheduler
# persona (rpms-rpc#420, #621). Setup files a visit for synthetic DFN 990054
# at DEMO IHS CLINIC (hospital location 3) at 3261118.1000, as PROFILE,MD with
# a BEHOENPC SAVE of its own (as tools/captured_replies/procedure-add.rb
# does), and books an appointment for that patient on 3261118.1100 that is
# never checked in. Run on a throwaway container.
Scheduling = RpmsRpc::Scheduling
DFN = 990_054
CLINIC = 3
VISIT_AT = "3261118.1000"
BOOKED = {} # the appointment setup books, for the flows

SETUP = lambda do |client|
  md = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: Integer(ENV.fetch("BROKER_PORT", "9100")), timeout: 30)
  md.connect
  md.authenticate("PMD123", "PMD123!!")
  pcc = { 1 => "HDR^0^^#{CLINIC};#{VISIT_AT};A", 2 => "VST^DT^#{VISIT_AT}", 3 => "VST^PT^#{DFN}",
          4 => "VST^HL^#{CLINIC}", 5 => "VST^VC^A", 6 => "PRV^#{md.duz}^^^^1" }
  reply = Array(md.call_rpc("BEHOENPC SAVE", pcc, "0", CLINIC.to_s))
  abort "setup: BEHOENPC SAVE answered #{reply.inspect}" unless reply == [ "0" ]
  md.disconnect

  raw = client.call_rpc_raw("BSDX ADD NEW APPOINTMENT", "3261118.1100", "3261118.1115", DFN.to_s, "DEMO IHS CLINIC",
                            "15", "", "", "").b
  id = raw.split("\x1E".b)[1].to_s.split("^").first
  abort "setup booked no appointment: #{raw.inspect}" unless id.to_i.positive?
  BOOKED[:id] = id
  {}
end

CAPTURE = {
  rpc: "BEHOENCX FETCH", entry_point: "FETCH^BEHOENCX",
  signed_on_as: "PROFILE,SCHED (PSCH123, a published demo pair)",
  access: "PSCH123", verify: "PSCH123!!", context: "BSDXRPC",
  note: "Run on a throwaway container. Setup files a visit for synthetic DFN 990054 at DEMO IHS CLINIC " \
        "(hospital location 3) at 3261118.1000 as PROFILE,MD, and books an appointment for DFN 990054 at " \
        "3261118.1100 that is never checked in. 999999 is an appointment IEN no record has.",
  setup: SETUP,
  flows: {
    "checkin_visit_found" => {
      about: "checkin_visit: DFN 990054 at clinic 3 at 3261118.1000, where setup filed a visit",
      run: -> { Scheduling.checkin_visit(dfn: DFN, clinic_ien: CLINIC, checkin_time: VISIT_AT) }
    },
    "checkin_non_numeric" => {
      about: "checkin_appointment: appointment ID abc",
      run: -> { Scheduling.checkin_appointment("abc", checkin_time: "3261118.1101") }
    },
    "checkin_unknown" => {
      about: "checkin_appointment: appointment ID 999999, which no record has",
      run: -> { Scheduling.checkin_appointment(999_999, checkin_time: "3261118.1101") }
    },
    "checkout_not_checked_in" => {
      about: "checkout_appointment: the appointment setup booked, never checked in",
      run: lambda {
        Scheduling.checkout_appointment(BOOKED.fetch(:id), patient_dfn: DFN, appointment_time: "3261118.1100",
                                                           checkout_time: "3261118.1110")
      }
    }
  }
}.freeze
