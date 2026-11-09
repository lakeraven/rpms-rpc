# frozen_string_literal: true

# ORWPS ACTIVE, as RpmsRpc::Medication.active_for_patient sends it (DFN only),
# on a throwaway container. rpms-rpc#620.
CAPTURE = {
  rpc: "ORWPS ACTIVE", entry_point: "ACTIVE^ORWPS",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Read-only. No demo patient on the build has a medication, so every reply is empty.",
  calls: [
    { name: "dfn_4", inputs: [ "4" ], about: "demo patient 4, who has no medication" }
  ]
}.freeze
