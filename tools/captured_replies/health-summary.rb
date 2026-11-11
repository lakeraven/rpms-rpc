# frozen_string_literal: true

require "rpms_rpc/api/health_summary"

# The conversations RpmsRpc::HealthSummary has with the build, recorded as
# PROFILE,MD on demo patient DFN 4: the IHS types the site lists (the
# [HEALTH SUMMARY TYPES] block of ORWRP REPORT LISTS), the ADULT REGULAR
# summary by name and the MEDICATIONS summary by IEN, through the IHS report
# (RPTID "IHS", HS^ORWRPBHS). Two direct calls keep what the gem must not
# send: a type the site does not have, and the old frame (report 1, which
# reads HSTYPE as a VA type, with type 1). rpms-rpc#662.
HS = RpmsRpc::HealthSummary

CAPTURE = {
  rpc: "ORWRP REPORT TEXT", entry_point: "RPT^ORWRP",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a throwaway container; reads only. DFN 4 is the build's demo patient DEMO,PATIENT ONE.",
  calls: [
    { name: "ihs_type_not_on_file", inputs: [ "4", "IHS", "999", "", "", "", "" ],
      about: "the IHS report with HSTYPE 999, which is not in #9001015: HSX^ORWRPBHS prints its fault" },
    { name: "report_1_type_1", inputs: [ "4", "1", "1", "", "", "", "" ], expect_error: true,
      about: "report 1 (HS^ORWRP1, VA types #142) with HSTYPE 1, the frame the gem sent before #662: the report faults" }
  ],
  flows: {
    "summary_types" => { about: "summary_types: the IHS types ORWRP REPORT LISTS lists",
                         run: -> { HS.summary_types } },
    "for_patient" => { about: "for_patient(4): ADULT REGULAR, the default type", run: -> { HS.for_patient(4) } },
    "for_patient_by_ien" => { about: "for_patient(4, summary_type: 55): MEDICATIONS, by IEN",
                              run: -> { HS.for_patient(4, summary_type: 55) } }
  }
}.freeze
