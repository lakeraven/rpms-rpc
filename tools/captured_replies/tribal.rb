# frozen_string_literal: true

# The seven Tribal reads, each a generic FileMan RPC (DDR GETS ENTRY DATA,
# DDR LISTER, DDR VALIDATOR) over IHS PATIENT (#9000001), TRIBE
# (#9999999.03), SERVICE UNIT (#9999999.22) and COMMUNITY (#9999999.05),
# recorded as flows as the registration persona PROFILE,REG. The patient is
# ALPHA,CASEY (DFN 990001), a synthetic panel patient whose enrollment number
# SEEDPNL files as SYN990001. Nothing is filed. rpms-rpc#616, #621.
Tribal = RpmsRpc::Tribal

CAPTURE = {
  rpc: "DDR GETS ENTRY DATA", entry_point: "GETSC^DDR2",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)",
  access: "PREG123", verify: "PREG123!!",
  note: "Run on a throwaway container; every call reads.",
  flows: {
    "enrollment" => { about: "enrollment: the #9000001 tribal fields of DFN 990001", run: -> { Tribal.enrollment(990_001) } },
    "enrollment_unknown" => { about: "enrollment: DFN 999999999, which is not on file", run: -> { Tribal.enrollment(999_999_999) } },
    "eligibility" => { about: "eligibility: classification and status of DFN 990001", run: -> { Tribal.eligibility(990_001) } },
    "validate_valid" => { about: "validate: SYN12345 against #9000001 .07's input transform", run: -> { Tribal.validate("SYN12345") } },
    "validate_invalid" => { about: "validate: a 40-character value, longer than .07 accepts", run: -> { Tribal.validate("X" * 40) } },
    "tribes" => { about: "tribes: names starting KWETH on the B index", run: -> { Tribal.tribes(part: "KWETH") } },
    "tribe_info" => { about: "tribe_info: TRIBE 697, KWETHLUK, INC.", run: -> { Tribal.tribe_info(697) } },
    "service_unit" => { about: "service_unit: SERVICE UNIT 1", run: -> { Tribal.service_unit(1) } },
    "communities" => { about: "communities: names starting STONEHAM on the B index", run: -> { Tribal.communities(part: "STONEHAM") } }
  }
}.freeze
