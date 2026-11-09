# frozen_string_literal: true

require "rpms_rpc/api/registration"
require "rpms_rpc/api/ddr_fileman"

# The conversations RpmsRpc::Registration's address-history, cell-phone and
# race-and-ethnicity methods have with the build (rpms-ops#1055), recorded as
# flows: each flow runs the gem as PROFILE,REG on seed patient DFN 990009 (DOB
# 1981-10-09) and keeps every reply, in order. rpms-rpc#621.
DFN = 990_009
Reg = RpmsRpc::Registration

def held_by_scheduler
  other = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: Integer(ENV.fetch("BROKER_PORT", "9100")), timeout: 30)
  other.connect
  other.authenticate("PSCH123", "PSCH123!!")
  other.create_context("AGGRPC")
  other.call_rpc_global_array("AGG LOCK PATIENT", DFN.to_s)
  yield
ensure
  other&.call_rpc_global_array("AGG UNLOCK PATIENT", DFN.to_s)
  other&.disconnect
end

CAPTURE = {
  rpc: "DDR FILER", entry_point: "FILEC^DDR3",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)",
  access: "PREG123", verify: "PREG123!!",
  note: "Run on a throwaway container: the flows file addresses, a cell phone and races for DFN 990009, in this " \
        "order, so each flow's replies follow from the ones before. Dates the gem computes are the capture day's.",
  flows: {
    "history_empty" => { about: "address_history before any move", run: -> { Reg.address_history(DFN) } },
    "move_first" => { about: "change_address: moved 400 days ago to 2 NEW RD",
                      run: -> { Reg.change_address(DFN, moved_on: Date.today - 400, address_line1: "2 NEW RD") } },
    "move_second" => { about: "change_address: moved 3 days ago to 3 NEWER RD",
                       run: -> { Reg.change_address(DFN, moved_on: Date.today - 3, address_line1: "3 NEWER RD") } },
    "unchanged" => { about: "change_address: only the work phone changes",
                     run: -> { Reg.change_address(DFN, phone_work: "406-555-0199") } },
    "before_birth" => { about: "change_address: a move dated before the date of birth",
                        run: -> { Reg.change_address(DFN, moved_on: Date.new(1980, 1, 1), address_line1: "4 EARLY RD") } },
    "history" => { about: "address_history after two moves", run: -> { Reg.address_history(DFN) } },
    "history_no_patient" => { about: "address_history of a DFN no patient holds",
                              run: -> { Reg.address_history(999_999) rescue nil } },
    "address_no_patient" => { about: "change_address of a DFN no patient holds",
                              run: -> { Reg.change_address(999_999, address_line1: "2 NEW RD") } },
    "cell_phone" => { about: "cell_phone of a patient with none on file", run: -> { Reg.cell_phone(DFN) } },
    "races_first" => { about: "set_race_ethnicity: one race, one ethnicity",
                       run: -> { Reg.set_race_ethnicity(DFN, races: [ { code: 14, method: 1 } ], ethnicities: [ { code: 2, method: 1 } ]) } },
    "races_replace" => { about: "set_race_ethnicity: replace them with two races, the second by proxy",
                         run: lambda {
                           Reg.set_race_ethnicity(DFN, races: [ { code: 2, method: 1 }, { code: 14, method: 2 } ],
                                                       ethnicities: [ { code: 2, method: 1 } ])
                         } },
    "declined_beside_another" => { about: "set_race_ethnicity: DECLINED TO ANSWER beside WHITE",
                                   run: lambda {
                                     Reg.set_race_ethnicity(DFN, races: [ { code: 11, method: 1 }, { code: 14, method: 1 } ],
                                                                 ethnicities: [ { code: 2, method: 1 } ])
                                   } },
    "inactive_race" => { about: "set_race_ethnicity: race 3, which the build marks inactive",
                         run: -> { Reg.set_race_ethnicity(DFN, races: [ { code: 3, method: 1 } ], ethnicities: [ { code: 2, method: 1 } ]) } },
    "lock_held" => { about: "set_race_ethnicity while another user holds AG's lock on the patient",
                     run: lambda {
                       held_by_scheduler do
                         Reg.set_race_ethnicity(DFN, races: [ { code: 2, method: 1 } ], ethnicities: [ { code: 2, method: 1 } ])
                       end
                     } },
    "races_read" => { about: "race_ethnicity after the replace", run: -> { Reg.race_ethnicity(DFN) } }
  }
}.freeze
