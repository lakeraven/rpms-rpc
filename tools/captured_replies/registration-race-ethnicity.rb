# frozen_string_literal: true

require "rpms_rpc/api/registration"
require "rpms_rpc/api/ddr_fileman"

# RpmsRpc::Registration.race_ethnicity read on the build as PROFILE,REG: each
# race and ethnicity row with its code file's 3 HL7 VALUE (rpms-rpc#830).
# DFN 4 is the demo patient with a race and an ethnicity on file. DFN 990011
# has none, so setup files it one legacy race straight through DDR FILER:
# #10 entry 3 (WHITE, NOT OF HISPANIC ORIGIN), which the build marks inactive
# and gives no HL7 VALUE, the way a record kept from before the CDC codes
# looks. set_race_ethnicity refuses an inactive code, so setup does not use it.
LEGACY_DFN = 990_011
LEGACY_RACE = 3

def file_legacy_race(session)
  RpmsRpc.configure { |cfg| cfg.client = session }
  RpmsRpc::ContextScope.scoped(session, RpmsRpc::Registration::CONTEXT) do
    rows = [ { file: "2.02", field: ".01", iens: "+1,#{LEGACY_DFN},", value: LEGACY_RACE.to_s },
             { file: "2.02", field: ".02", iens: "+1,#{LEGACY_DFN},", value: "1" } ]
    filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows, iens: { 1 => LEGACY_RACE })
    abort "setup: DDR FILER did not file the legacy race: #{filed.inspect}" unless filed&.dig(:success)
  end
  {}
ensure
  RpmsRpc.reset!
end

CAPTURE = {
  rpc: "DDR GETS ENTRY DATA", entry_point: "GETSC^DDR2",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)",
  access: "PREG123", verify: "PREG123!!",
  context: "CIAV VUECENTRIC",
  note: "Run on a throwaway container. Setup files #10 entry 3, an inactive legacy race with no HL7 VALUE, " \
        "for DFN 990011 through DDR FILER before the flows run.",
  setup: ->(session) { file_legacy_race(session) },
  calls: [
    { name: "code_not_on_file", inputs: [ { "FILE" => "10", "IENS" => "999999,", "FIELDS" => "3", "FLAGS" => "I" } ],
      about: "the 3 HL7 VALUE of a #10 entry the build does not have" }
  ],
  flows: {
    "on_file" => { about: "race_ethnicity(4): AMERICAN INDIAN OR ALASKA NATIVE and NOT HISPANIC OR LATINO on file",
                   run: -> { RpmsRpc::Registration.race_ethnicity(4) } },
    "legacy_code" => { about: "race_ethnicity(990011): a legacy race whose #10 entry has no HL7 VALUE",
                       run: -> { RpmsRpc::Registration.race_ethnicity(LEGACY_DFN) } }
  }
}.freeze
