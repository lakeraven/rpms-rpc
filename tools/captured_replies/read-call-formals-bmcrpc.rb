# frozen_string_literal: true

# BMC SEARCH REFERRAL in the six-formal frame Referral.for_patient sends, for
# demo patient DFN 4, under BMCRPC, the context Referral binds.
# rpms-rpc#621.
CAPTURE = {
  rpc: "BMC SEARCH REFERRAL", entry_point: "SRCHREF^BMCRPC1",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!", context: "BMCRPC",
  note: "Seed patient DFN 4 (synthetic data); a read.",
  calls: [
    { name: "dfn_4", inputs: [ "4", "", "", "", "", "" ], about: "Referral.for_patient: DFN and five empty filters" }
  ]
}.freeze
