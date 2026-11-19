# frozen_string_literal: true

require "rpms_rpc/api/medication"

# ORQQPS LIST then ORQQPS DETAIL, as RpmsRpc::Medication.find sends them (the
# patient's whole medication list, then the patient and the medication id),
# recorded as flows on a throwaway container. rpms-rpc#678, rpms-rpc#837.
CAPTURE = {
  rpc: "ORQQPS DETAIL", entry_point: "DETAIL^ORQQPS",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Read-only. The demo build seeds USER,TEST (DFN 2) one prescription (1R;O) and one pending order (2P;O); " \
        "DEMO,PATIENT ONE (DFN 4) has no medication.",
  flows: {
    "find_own" => { about: "find(2, \"1R;O\"): the seed patient's own prescription, on its list",
                    run: -> { RpmsRpc::Medication.find(2, "1R;O") } },
    "find_another_patients" => { about: "find(4, \"1R;O\"): patient 4 and patient 2's prescription, not on patient 4's list",
                                 run: -> { RpmsRpc::Medication.find(4, "1R;O") } },
    "find_inpatient_not_listed" => { about: "find(2, \"1U;I\"): an inpatient order id the seed patient's list does not give",
                                     run: -> { RpmsRpc::Medication.find(2, "1U;I") } }
  }
}.freeze
