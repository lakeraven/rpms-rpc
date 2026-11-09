# frozen_string_literal: true

# ORQQPXRM REMINDERS APPLICABLE, as RpmsRpc::Reminders.applicable sends it:
# the build's own reminder evaluation (APPL^ORQQPXRM -> AVAL^PXRMRPCA).
# rpms-rpc#621.
CAPTURE = {
  rpc: "ORQQPXRM REMINDERS APPLICABLE", entry_point: "APPL^ORQQPXRM",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Seed patients DFN 4 and DFN 3 (synthetic data); location 6 is DEMO PRIMARY CARE. Evaluation files nothing.",
  calls: [
    { name: "dfn_4", inputs: [ "4", "" ], about: "DFN 4, no location: due, applicable and cannot-be-determined rows" },
    { name: "dfn_4_at_location", inputs: [ "4", "6" ], about: "DFN 4 at DEMO PRIMARY CARE" },
    { name: "dfn_3", inputs: [ "3", "" ], about: "DFN 3, no location: not-applicable rows" },
    { name: "no_such_patient", inputs: [ "999999", "" ], about: "a DFN no patient holds" }
  ]
}.freeze
