# frozen_string_literal: true

# DDR GETS ENTRY DATA on HEALTH FACTORS (#9999999.64) .01, FLAGS "I", the
# read Encounter.save makes before BEHOENPC SAVE to refuse a health factor
# IEN the build has no entry for (rpms-rpc#928): HEALTH FACTOR 25 (the entry
# the encounter-save capture files) and 999999, which is not on file. Signed
# on as PROFILE,MD, in CIAV VUECENTRIC, the context the save runs in.
CAPTURE = {
  rpc: "DDR GETS ENTRY DATA", entry_point: "GETSC^DDR2",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  context: "CIAV VUECENTRIC",
  note: "Read-only. HEALTH FACTOR 25 is the build's own entry; 999999 is not on file.",
  calls: [
    { name: "on_file",
      inputs: [ { "FILE" => "9999999.64", "IENS" => "25,", "FIELDS" => ".01", "FLAGS" => "I" } ],
      about: "HEALTH FACTOR 25, on file" },
    { name: "not_on_file",
      inputs: [ { "FILE" => "9999999.64", "IENS" => "999999,", "FIELDS" => ".01", "FLAGS" => "I" } ],
      about: "HEALTH FACTOR 999999, not on file" }
  ]
}.freeze
