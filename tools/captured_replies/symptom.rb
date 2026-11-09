# frozen_string_literal: true

# ORWDAL32 SYMPTOMS and ORWDAL32 DEF, as RpmsRpc::Symptom.search and
# Symptom.defaults send them. rpms-rpc#621.
CAPTURE = {
  rpc: "ORWDAL32 SYMPTOMS", entry_point: "SYMPTOMS^ORWDAL32",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "The symptom file (120.83) and the allergy-entry defaults are the build's own tables; nothing is filed.",
  calls: [
    { name: "from_rash", inputs: [ "RASH", "1" ], about: "the page of symptoms after RASH, walking forward" },
    { name: "past_the_end", inputs: [ "ZZZZZZ", "1" ], about: "a FROM past the last symptom: nothing follows" },
    { name: "defaults", rpc: "ORWDAL32 DEF", inputs: [], about: "the allergy-entry defaults tree" }
  ]
}.freeze
