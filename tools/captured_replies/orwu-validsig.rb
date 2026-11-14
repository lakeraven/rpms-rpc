# frozen_string_literal: true

# ORWU VALIDSIG as PROFILE,MA, whose demo signature code SEEDPERS files (openrpms
# reconciliation/shared/SEEDPERS.m, published like the sign-on pairs). rpms-rpc#601.
CAPTURE = {
  rpc: "ORWU VALIDSIG", entry_point: "VALIDSIG^ORWU",
  signed_on_as: "PROFILE,MA (PMA123, a published demo pair; DUZ 204)",
  access: "PMA123", verify: "PMA123!!",
  note: "The one wire parameter is the XWB-encrypted signature code. The cipher picks a random row pair, " \
        "so the inputs are withheld; the reply is what a test reads.",
  calls: [
    { name: "stored_code", inputs: [ "<the persona's demo signature code, encrypted; withheld>" ],
      about: "the code SEEDPERS files for PROFILE,MA",
      wire_inputs: ->(_client) { [ RpmsRpc::ValidSignature.encrypt("123456") ] } },
    { name: "other_code", inputs: [ "<a code the persona does not hold, encrypted; withheld>" ],
      about: "a six-digit code that is not the persona's",
      wire_inputs: ->(_client) { [ RpmsRpc::ValidSignature.encrypt("999999") ] } }
  ]
}.freeze
