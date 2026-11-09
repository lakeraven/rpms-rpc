# frozen_string_literal: true

# The chart list reads RpmsRpc::Allergy, Problem, Vital, Medication and
# Encounter make, each with the frame the gem sends, for seed patients on a
# throwaway container. rpms-rpc#619.
CAPTURE = {
  rpc: "ORQQAL LIST", entry_point: "LIST^ORQQAL",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Read-only: nothing is filed. Rows are the build's demo patients and their seeded data.",
  calls: [
    { name: "allergies_dfn_2", inputs: [ "2" ], about: "demo patient 2: one allergy with a sign" },
    { name: "allergies_dfn_4", inputs: [ "4" ], about: "demo patient 4: one allergy, no sign" },
    { name: "allergies_unassessed", inputs: [ "1" ], about: "demo patient 1: no allergy assessment" },
    { name: "problems_dfn_2", rpc: "ORQQPL LIST", inputs: [ "2", "" ], about: "demo patient 2, all statuses" },
    { name: "problems_none", rpc: "ORQQPL LIST", inputs: [ "1", "" ], about: "demo patient 1, who has no problems" },
    { name: "vitals_dfn_4", rpc: "ORQQVI VITALS", inputs: [ "4" ], about: "demo patient 4's latest vitals" },
    { name: "vitals_none", rpc: "ORQQVI VITALS", inputs: [ "99999" ], about: "a DFN no patient holds" },
    { name: "medications_none", rpc: "ORQQPS LIST", inputs: [ "4", "", "" ],
      about: "demo patient 4's condensed medication list; no demo patient has a medication" },
    { name: "medication_detail_one_param", rpc: "ORQQPS DETAIL", inputs: [ "1" ], expect_error: true,
      about: "the one-parameter frame Medication.find sends to DETAIL(ORY,ORPT,ORMED)^ORQQPS" },
    { name: "appointments_dfn_4", rpc: "ORWPT APPTLST", inputs: [ "4" ], about: "demo patient 4: no appointments in the window" },
    { name: "appointments_dfn_1", rpc: "ORWPT APPTLST", inputs: [ "1" ], about: "demo patient 1" }
  ]
}.freeze
