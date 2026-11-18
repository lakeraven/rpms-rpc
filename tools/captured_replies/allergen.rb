# frozen_string_literal: true

# ORWDAL32 ALLERGY MATCH, as RpmsRpc::Allergen.search sends it. rpms-rpc#762.
CAPTURE = {
  rpc: "ORWDAL32 ALLERGY MATCH", entry_point: "ALLSRCH^ORWDAL32",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  context: "CIAV VUECENTRIC",
  note: "GMR ALLERGIES (120.82) and the National Drug File are the build's own tables; nothing is filed.",
  calls: [
    { name: "strawb", inputs: [ "STRAWB" ], about: "an allergen by name and by synonym (GMR ALLERGIES)" },
    { name: "aspirin_comma", inputs: [ "ASPIRIN," ], about: "synonyms of an allergen, and drug trade names" },
    { name: "amoxicillin", inputs: [ "AMOXICILLIN" ], about: "drug generic and trade names" },
    { name: "latex", inputs: [ "LATEX" ], about: "a drug ingredient" },
    { name: "penicillins", inputs: [ "PENICILLINS" ], about: "VA drug classes" },
    { name: "no_match", inputs: [ "ZZZQX" ], about: "text nothing matches: only the source headers" }
  ]
}.freeze
