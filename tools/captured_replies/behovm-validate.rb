# frozen_string_literal: true

require "rpms_rpc/api/vital"

# The BEHOVM VALIDATE conversations RpmsRpc::Vital.validate has with the
# build, recorded as flows as PROFILE,MD: values it accepts, one it refuses
# out of range and one it refuses as not numeric, a value in other units it
# converts, and a vital type the build does not have. One direct call keeps
# the frame the gem sent before #665 ("TMP|97" and a DFN), which dies in M.
# Nothing is filed. rpms-rpc#665.
Vital = RpmsRpc::Vital

CAPTURE = {
  rpc: "BEHOVM VALIDATE", entry_point: "VALIDATE^BEHOVM",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a throwaway container; VALIDATE files nothing.",
  calls: [
    { name: "old_frame", inputs: [ "TMP|97", "4" ], expect_error: true,
      about: "the frame validate sent before #665: VALIDATE dies on X (LVUNDEF)" }
  ],
  flows: {
    "accepted" => {
      about: "validate: TMP 97, PU 80 and BP 130/90 in each type's default units",
      run: -> { Vital.validate(4, [ { abbreviation: "TMP", value: 97 }, { abbreviation: "PU", value: 80 },
                                    { abbreviation: "BP", value: "130/90" } ]) }
    },
    "refused" => {
      about: "validate: TMP 97, then TMP 999 (out of range) and TMP blank (not numeric)",
      run: -> { Vital.validate(4, [ { abbreviation: "TMP", value: 97 }, { abbreviation: "TMP", value: 999 },
                                    { abbreviation: "TMP", value: "" } ]) }
    },
    "converted" => {
      about: "validate: TMP 36C, which the build converts to its default units (F)",
      run: -> { Vital.validate(4, [ { abbreviation: "TMP", value: "36C" } ]) }
    },
    "metric" => {
      about: "validate with metric: 1: TMP 97, out of range in C",
      run: -> { Vital.validate(4, [ { abbreviation: "TMP", value: 97 } ], metric: 1) }
    },
    "unknown_type" => {
      about: "validate: ZZZ, a vital type the build does not have: the routine faults",
      run: -> { Vital.validate(4, [ { abbreviation: "ZZZ", value: 5 } ]) }
    }
  }
}.freeze
