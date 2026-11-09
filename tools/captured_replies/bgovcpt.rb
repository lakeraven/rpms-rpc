# frozen_string_literal: true

# BGOVCPT GET, as RpmsRpc::Procedure.for_patient reads it, and BGOVCPT SET
# in the three-parameter frame Procedure.add sends today, which the build
# refuses (rpms-rpc#524). rpms-rpc#621.
CAPTURE = {
  rpc: "BGOVCPT GET", entry_point: "GET^BGOVCPT",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "DFN 4 carries the build's seeded V CPT entries. The SET frame faults before anything is filed (ACTLSTTOOLONG).",
  calls: [
    { name: "dfn_4", inputs: [ "4" ], about: "the V CPT entries of demo patient DFN 4" },
    { name: "set_three_params", rpc: "BGOVCPT SET", inputs: [ "4", "4", "99213^^office visit^1" ], expect_error: true,
      about: "Procedure.add's frame: SET(RET,INP) takes one parameter, so the build refuses three" }
  ]
}.freeze
