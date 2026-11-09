# frozen_string_literal: true

# BGOREF GETREA, the refusal reasons for a refusal type, as
# ImmunizationRefusal.reasons asks for them. rpms-rpc#620.
CAPTURE = {
  rpc: "BGOREF GETREA", entry_point: "GETREA^BGOREF",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "The reasons are the build's own table; nothing is filed.",
  calls: [
    { name: "immunization", inputs: [ "IMMUNIZATION" ], about: "the IMMUNIZATION refusal type (the default)" },
    { name: "no_such_type", inputs: [ "NOT A REFUSAL TYPE" ], about: "a type name the build does not have" }
  ]
}.freeze
