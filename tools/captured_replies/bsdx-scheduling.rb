# frozen_string_literal: true

# The BSDX conversations RpmsRpc::Scheduling has, as the scheduler persona, on a
# throwaway container: every read on the demo clinic, then one appointment
# taken through check-in, check-out, no-show, cancel and uncancel, with the
# routines' own refusals for the moves they do not allow. rpms-rpc#621.
APPT = ->(s) { s.fetch(:appointment) }
OTHER = ->(s) { s.fetch(:other) }

CAPTURE = {
  rpc: "BSDX ADD NEW APPOINTMENT", entry_point: "APPADD^BSDX07",
  signed_on_as: "PROFILE,SCHED (PSCH123, a published demo pair)",
  access: "PSCH123", verify: "PSCH123!!", context: "BSDXRPC",
  setup: lambda { |client|
    book = lambda do |start, finish|
      raw = client.call_rpc_raw("BSDX ADD NEW APPOINTMENT", start, finish, "4", "DEMO IHS CLINIC", "15", "", "", "").b
      id = raw.split("\x1E".b)[1].to_s.split("^").first
      raise "setup booked no appointment: #{raw.inspect}" unless id.to_i.positive?

      id
    end
    { appointment: book.call("3261109.0800", "3261109.0815"), other: book.call("3261109.0830", "3261109.0845") }
  },
  note: "Seed patient DFN 4 and the demo clinic (DEMO IHS CLINIC: hospital location 3, resource 2), synthetic " \
        "data. Setup books appointment A at 3261109.0800 and C at 3261109.0830; the inputs that name them read their IENs. 999999 is an " \
        "appointment IEN no record has. The checkout_future refusal depends on the capture date (the " \
        "captured_at below). The check-in visit read binds CIAV VUECENTRIC, where BEHOENCX FETCH is served.",
  calls: [
    { name: "hospital_locations", rpc: "BSDX HOSPITAL LOCATION", inputs: [], about: "every clinic" },
    { name: "clinic_setup", rpc: "BSDX CLINIC SETUP", inputs: [], about: "every clinic's setup" },
    { name: "resources", rpc: "BSDX RESOURCES", inputs: [ "" ], about: "every resource" },
    { name: "resources_by_user", rpc: "BSDX RESOURCES BY USER", inputs: [ "" ], about: "the signed-on user's resources" },
    { name: "availability", rpc: "BSDX SEARCH AVAILABILITY",
      inputs: [ "DEMO IHS CLINIC", "3261116", "3261116", "", "", "" ], about: "the demo clinic's open blocks on one day" },
    { name: "availability_unknown_resource", rpc: "BSDX SEARCH AVAILABILITY",
      inputs: [ "NO SUCH RESOURCE", "3261116", "3261116", "", "", "" ], about: "a resource name no record has" },
    { name: "all_appointments", rpc: "BSDX ALL APPOINTMENTS", inputs: [ "3261109", "3261109" ],
      about: "every appointment on A's day" },
    { name: "all_appointments_none", rpc: "BSDX ALL APPOINTMENTS", inputs: [ "3261117", "3261117" ],
      about: "a day with no appointment" },
    { name: "slot_schedule", rpc: "BSDX CREATE ASGND SLOT SCHED",
      inputs: [ "DEMO IHS CLINIC", "3261116.0001", "3261116.2359", "", "" ], about: "the demo clinic's slots on one day" },
    { name: "slot_schedule_unknown_resource", rpc: "BSDX CREATE ASGND SLOT SCHED",
      inputs: [ "NO SUCH RESOURCE", "3261116.0001", "3261116.2359", "", "" ], about: "a resource name no record has" },
    { name: "appointments", rpc: "BSDX CREATE APPT SCHEDULE",
      inputs: [ "DEMO IHS CLINIC", "3261109.0001", "3261109.2359", "" ], about: "the demo clinic's appointments on A's day" },
    { name: "appointments_none", rpc: "BSDX CREATE APPT SCHEDULE",
      inputs: [ "DEMO IHS CLINIC", "3261117.0001", "3261117.2359", "" ], about: "a day with no appointment" },
    { name: "patient_appointments_none", rpc: "BSDX PATIENT APPT DISPLAY", inputs: [ "999999999" ],
      about: "a DFN no patient has" },
    { name: "overbook", rpc: "BSDX OVERBOOK", inputs: [ "3", "3261109.0800", "2" ], about: "may A's slot be overbooked" },
    { name: "variable_length", rpc: "BSDX CLINIC VAR APPT", inputs: [ "3" ], about: "does the clinic allow variable lengths" },
    { name: "add", inputs: [ "3261116.0900", "3261116.0915", "4", "DEMO IHS CLINIC", "15", "synthetic", "", "" ],
      about: "book appointment B" },
    { name: "add_unknown_resource", inputs: [ "3261116.0900", "3261116.0915", "4", "NO SUCH RESOURCE", "15", "", "", "" ],
      about: "book on a resource name no record has" },
    { name: "checkin", rpc: "BSDX CHECKIN APPOINTMENT", inputs: ->(s) { [ APPT.(s), "3261109.0801", "", "", "", "", "", "" ] },
      about: "check A in" },
    { name: "checkin_missing", rpc: "BSDX CHECKIN APPOINTMENT", inputs: [ "999999", "3261109.0801", "", "", "", "", "", "" ],
      about: "check in an appointment IEN no record has" },
    { name: "checkout_future", rpc: "BSDX CHECKOUT APPOINTMENT", inputs: ->(s) { [ "4", "3261109.0800", "3261201.0900", APPT.(s), "" ] },
      about: "check A out at a time after the capture" },
    { name: "checkout", rpc: "BSDX CHECKOUT APPOINTMENT", inputs: ->(s) { [ "4", "3261109.0800", "3261109.0810", APPT.(s), "" ] },
      about: "check A out" },
    { name: "cancel_checkout", rpc: "BSDX CANCEL CHECKOUT APPT", inputs: ->(s) { [ APPT.(s) ] }, about: "undo A's check-out" },
    { name: "cancel_checkout_not_checked_out", rpc: "BSDX CANCEL CHECKOUT APPT", inputs: ->(s) { [ APPT.(s) ] },
      about: "undo it again: A is not checked out" },
    { name: "cancel_checkin", rpc: "BSDX CHECKIN APPOINTMENT", inputs: ->(s) { [ APPT.(s), "@", "", "", "", "", "", "" ] },
      about: "undo A's check-in" },
    { name: "edit", rpc: "BSDX EDIT APPOINTMENT", inputs: ->(s) { [ APPT.(s), "synthetic edit", "20" ] },
      about: "edit A's note and length" },
    { name: "no_show", rpc: "BSDX NOSHOW", inputs: ->(s) { [ APPT.(s), "1" ] }, about: "mark A a no-show" },
    { name: "clear_no_show", rpc: "BSDX NOSHOW", inputs: ->(s) { [ APPT.(s), "0" ] }, about: "clear the no-show" },
    { name: "no_show_missing", rpc: "BSDX NOSHOW", inputs: [ "999999", "1" ], about: "an appointment IEN no record has" },
    { name: "cancel", rpc: "BSDX CANCEL APPOINTMENT", inputs: ->(s) { [ APPT.(s), "C", "1", "moved" ] },
      about: "cancel A, clinic-cancelled, reason 1, with a note" },
    { name: "cancel_missing", rpc: "BSDX CANCEL APPOINTMENT", inputs: [ "999999", "C", "1", "" ],
      about: "an appointment IEN no record has" },
    { name: "uncancel", rpc: "BSDX UNCANCEL APPT", inputs: ->(s) { [ APPT.(s) ] }, about: "restore A" },
    { name: "cancel_by_patient", rpc: "BSDX CANCEL APPOINTMENT", inputs: ->(s) { [ OTHER.(s), "PC", "1", "" ] },
      about: "cancel C, patient-cancelled" },
    { name: "uncancel_patient_cancelled", rpc: "BSDX UNCANCEL APPT", inputs: ->(s) { [ OTHER.(s) ] }, expect_error: true,
      about: "restore C: APPUDEL^BSDX08 refuses a patient-cancelled appointment, but its TROLLBACK runs twice " \
             "(again inside ERR), and on YottaDB the second one is an M error (TLVLZERO)" },
    { name: "add_availability", rpc: "BSDX ADD NEW AVAILABILITY",
      inputs: [ "3261207.0800", "3261207.1200", "1", "DEMO IHS CLINIC", "2", "" ], about: "open a block of two slots" },
    { name: "cancel_availability", rpc: "BSDX CANCEL AV BY DATE", inputs: [ "2", "3261207", "3261207" ],
      about: "cancel that day's blocks on resource 2" },
    { name: "checkin_visit", rpc: "BEHOENCX FETCH", context: "CIAV VUECENTRIC", inputs: [ "4", "3;3261109.0801;A", "", "0" ],
      about: "the visit for A's check-in, read without creating one" }
  ]
}.freeze
