# frozen_string_literal: true

require "rpms_rpc/api/medication"

# ORQQPS DETAIL, as RpmsRpc::Medication.find sends it (the patient, then the
# medication id), recorded as flows on a throwaway container. rpms-rpc#678.
CAPTURE = {
  rpc: "ORQQPS DETAIL", entry_point: "DETAIL^ORQQPS",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Read-only. No demo patient on the build has a medication, so each id is one the patient does not have.",
  flows: {
    "find_outpatient" => { about: "find(4, \"1R;O\"): demo patient 4, an outpatient prescription id",
                           run: -> { RpmsRpc::Medication.find(4, "1R;O") } },
    "find_inpatient" => { about: "find(4, \"1U;I\"): demo patient 4, an inpatient order id",
                          run: -> { RpmsRpc::Medication.find(4, "1U;I") } }
  }
}.freeze
