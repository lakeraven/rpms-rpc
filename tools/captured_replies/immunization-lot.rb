# frozen_string_literal: true

require "rpms_rpc/api/ddr_fileman"

# The DDR reads RpmsRpc::ImmunizationLot makes, of lot 1, as
# test/live/immunization_lot_live_test.rb filed and then retired it (INACTIVE)
# on the same throwaway container just before. rpms-rpc#620.
CAPTURE = {
  rpc: "DDR GETS ENTRY DATA", entry_point: "GETSC^DDR2",
  signed_on_as: "SYS123 (the build's operator, MANAGER,SYSTEM)",
  access: "SYS123", verify: "RPMS.000",
  note: "Run after the immunization lot live spec. Inputs are the DdrFileman params ImmunizationLot sends.",
  calls: [
    { name: "lot", about: "IMMUNIZATION LOT 1: number, status, vaccine, expiration, source",
      inputs: [ RpmsRpc::DdrFileman.gets_entry_param(file: "9999999.41", iens: "1,", fields: ".01;.03;.04;.09;.13", flags: "IE") ] },
    { name: "vaccine", about: "IMMUNIZATION 104, the lot's vaccine: name and HL7-CVX code",
      inputs: [ RpmsRpc::DdrFileman.gets_entry_param(file: "9999999.14", iens: "104,", fields: ".01;.03", flags: "I") ] },
    { name: "no_such_lot", about: "a lot IEN that does not exist",
      inputs: [ RpmsRpc::DdrFileman.gets_entry_param(file: "9999999.41", iens: "999999999,", fields: ".01;.03;.04;.09;.13", flags: "IE") ] },
    { name: "lister", rpc: "DDR LISTER", about: "every lot, the fields ImmunizationLot.list asks for",
      inputs: [ RpmsRpc::DdrFileman.lister_param(file: "9999999.41", fields: ".01I;.03I;.04I;.09I;.13I", flags: "IP") ] }
  ]
}.freeze
