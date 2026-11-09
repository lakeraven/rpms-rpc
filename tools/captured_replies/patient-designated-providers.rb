# frozen_string_literal: true

# The reads Patient.brief_header makes while seed patient DFN 2 gains
# designated providers, on a throwaway container. BEHOPTPC SETBDP files them
# (AEDAP^BDPAPI, the stock call), so GETBDP and PTINFO answer what RPMS keeps:
# none, then a case manager, then a case manager and a designated primary
# provider. rpms-rpc#620.
CAPTURE = {
  rpc: "BEHOPTPC GETBDP", entry_point: "GETBDP^BEHOPTPC",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  note: "Seed patient DFN 2 (synthetic data). The SETBDP captures are the writes between the reads: " \
        "PROFILE,REG (DUZ 207) as CASE MANAGER, then PROFILE,MD (DUZ 206) as DESIGNATED PRIMARY PROVIDER.",
  calls: [
    { name: "ptinfo_none", rpc: "BEHOPTCX PTINFO", inputs: [ "2" ], about: "demographics before any designation" },
    { name: "getbdp_none", inputs: [ "2" ], about: "no designated provider on file" },
    { name: "set_case_manager", rpc: "BEHOPTPC SETBDP", inputs: [ "2", "CASE MANAGER", "207" ],
      about: "file PROFILE,REG as the case manager" },
    { name: "ptinfo_case_manager", rpc: "BEHOPTCX PTINFO", inputs: [ "2" ], about: "demographics with only a case manager" },
    { name: "getbdp_case_manager", inputs: [ "2" ], about: "one row, CASE MANAGER" },
    { name: "set_primary", rpc: "BEHOPTPC SETBDP", inputs: [ "2", "DESIGNATED PRIMARY PROVIDER", "206" ],
      about: "file PROFILE,MD as the designated primary provider" },
    { name: "ptinfo_primary", rpc: "BEHOPTCX PTINFO", inputs: [ "2" ], about: "demographics with a designated primary provider" },
    { name: "getbdp_primary", inputs: [ "2" ], about: "two rows by category name: CASE MANAGER first" },
    { name: "cwad", rpc: "ORWPT CWAD", inputs: [ "2" ], about: "DFN 2's CWAD letters" },
    { name: "ptinfo_unknown", rpc: "BEHOPTCX PTINFO", inputs: [ "999999999" ], about: "a DFN no patient has" },
    { name: "getbdp_unknown", inputs: [ "999999999" ], about: "the same DFN: no rows" }
  ]
}.freeze
