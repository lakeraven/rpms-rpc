# frozen_string_literal: true

# The three reads Patient.brief_header makes, for the L2 demo patient, as
# PROFILE,MD under CIAV VUECENTRIC. rpms-rpc#623.
CAPTURE = {
  rpc: "BEHOPTCX PTINFO", entry_point: "PTINFO^BEHOPTCX",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Seed patient DFN 4 (synthetic data).",
  calls: [
    { name: "ptinfo", inputs: [ "4" ], about: "the banner's demographics" },
    { name: "getbdp", rpc: "BEHOPTPC GETBDP", inputs: [ "4" ], about: "the designated providers" },
    { name: "cwad", rpc: "ORWPT CWAD", inputs: [ "4" ], about: "the CWAD letters" }
  ]
}.freeze
