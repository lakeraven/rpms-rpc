# frozen_string_literal: true

require "rpms_rpc/api/registration_parameters"
require "rpms_rpc/api/ddr_fileman"

# REGISTRATION PARAMETERS (#9009061), as RpmsRpc::RegistrationParameters
# .for_facility reads it: DDR LISTER over the file, its MANDATORY FIELDS
# (SITE) multiple (#9009061.11) and each REQUIRED FIELD NAME multiple
# (#9009061.1101), and DDR GETS ENTRY DATA for the switches. Read only.
CAPTURE = {
  rpc: "DDR LISTER", entry_point: "LISTC^DDR",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair)",
  access: "PREG123", verify: "PREG123!!",
  context: "CIAV VUECENTRIC",
  note: "The build's demo division (INSTITUTION 7819) and its registration parameters; nothing is filed.",
  calls: [
    { name: "mandatory_files_of_absent_facility",
      inputs: [ { "FILE" => "9009061.11", "IENS" => ",999999,", "FIELDS" => "@;.01I", "FLAGS" => "IP", "MAX" => "100" } ],
      about: "the mandatory-field files of a facility with no entry: what LISTC^DDR answers for a parent that does not exist" },
    { name: "switches_of_absent_facility", rpc: "DDR GETS ENTRY DATA",
      inputs: [ { "FILE" => "9009061", "IENS" => "999999,", "FIELDS" => "1", "FLAGS" => "I" } ],
      about: "a switch of a facility with no entry: GETSC^DDR2's refusal, the shape of a failed read" }
  ],
  flows: {
    "division" => {
      about: "for_facility for the demo division 7819, as the registration persona",
      run: -> { RpmsRpc::RegistrationParameters.for_facility(7819) }
    },
    "not_on_file" => {
      about: "for_facility for INSTITUTION 999999, which has no #9009061 entry",
      run: -> { RpmsRpc::RegistrationParameters.for_facility(999_999) }
    }
  }
}.freeze
