# frozen_string_literal: true

# ORWPT ID INFO, a patient's identifying line, as the pilot readiness grader
# reads it (test/rpms_rpc/pilot_chart_reads_test.rb). rpms-rpc#604 item 3:
# a reply with both SSN and DOB blank grades not proven.
CAPTURE = {
  rpc: "ORWPT ID INFO", entry_point: "IDINFO^ORWPT",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!", context: "CIAV VUECENTRIC",
  note: "Reads only. No demo patient has both SSN and DOB blank; the bad-patient reply is the one real reply that does.",
  calls: [
    { name: "no_such_patient", inputs: [ "999999" ], about: "a DFN no patient has: every piece blank, SSN and DOB included" },
    { name: "blank_ssn", inputs: [ "2" ], about: "demo patient 2 (USER,TEST): SSN blank, DOB and the rest filed" }
  ]
}.freeze
