# frozen_string_literal: true

# RpmsRpc::Adt.admissions, current_location and discharge_datetime read on the
# build as PROVIDER,TEST (rpms-rpc#619). The build ships no inpatient stay
# (openrpms#1263), so before this capture two stays were filed on the throwaway
# container through stock $$ADD^BDGAPI, as openrpms
# test/inpatient_adt_build_level.sh calls it, on the build's DEMO WARD:
# DEMO,PATIENT ONE (DFN 4) admitted 3261110.083022 and discharged 3261112.1
# (10:00), and MIKE,SKYLER (DFN 990013) admitted 3261115.09 and still in.
# LIMA,REESE (DFN 990012) has no stay.
CAPTURE = {
  rpc: "ORWPT ADMITLST", entry_point: "ADMITLST^ORWPT",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair)",
  access: "PROV123", verify: "PROV123!!",
  context: "CIAV VUECENTRIC",
  note: "Run on a throwaway container. Before the run, DFN 4 was admitted (3261110.083022) and discharged " \
        "(3261112.1), and DFN 990013 admitted (3261115.09), on DEMO WARD through stock $$ADD^BDGAPI; " \
        "the build ships no stay (openrpms#1263).",
  calls: [
    { name: "admitlst_one_stay", inputs: [ "4" ], about: "ORWPT ADMITLST for DFN 4: one admission, discharged" },
    { name: "admitlst_no_stay", inputs: [ "990012" ], about: "ORWPT ADMITLST for DFN 990012: never admitted" },
    { name: "inploc_admitted", rpc: "ORWPT INPLOC", inputs: [ "990013" ],
      about: "ORWPT INPLOC for DFN 990013: admitted to DEMO WARD, which is linked to its hospital location" },
    { name: "inploc_discharged", rpc: "ORWPT INPLOC", inputs: [ "4" ], about: "ORWPT INPLOC for DFN 4: discharged" },
    { name: "inploc_never_admitted", rpc: "ORWPT INPLOC", inputs: [ "990012" ],
      about: "ORWPT INPLOC for DFN 990012: never admitted" },
    { name: "discharge_on_file", rpc: "ORWPT DISCHARGE", inputs: [ "4", "3261110.083022" ],
      about: "ORWPT DISCHARGE for DFN 4's admission: discharged at 10:00" },
    { name: "discharge_still_in", rpc: "ORWPT DISCHARGE", inputs: [ "990013", "3261115.0900" ],
      about: "ORWPT DISCHARGE for DFN 990013's admission: not discharged yet" },
    { name: "discharge_unknown_admission", rpc: "ORWPT DISCHARGE", inputs: [ "4", "3261110.0830" ],
      about: "ORWPT DISCHARGE for a datetime that is not DFN 4's admission (its minute, without the seconds)" }
  ]
}.freeze
