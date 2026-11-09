# frozen_string_literal: true

# BGOVCPT GET, as RpmsRpc::Procedure.for_patient reads it. rpms-rpc#621.
# Procedure.add files through BEHOENPC SAVE (procedure-add.rb, rpms-rpc#524).
CAPTURE = {
  rpc: "BGOVCPT GET", entry_point: "GET^BGOVCPT",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "DFN 4 carries the build's seeded V CPT entries.",
  calls: [
    { name: "dfn_4", inputs: [ "4" ], about: "the V CPT entries of demo patient DFN 4" }
  ]
}.freeze
