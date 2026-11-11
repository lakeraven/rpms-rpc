# frozen_string_literal: true

require "rpms_rpc/api/procedure"
require "rpms_rpc/api/ddr_fileman"

# The BEHOENPC SAVE conversations RpmsRpc::Procedure.add has with the build,
# recorded as flows as PROFILE,MD (rpms-rpc#524). Setup files a visit for
# synthetic DFN 990054 today at DEMO PRIMARY CARE with a BEHOENPC SAVE of its
# own (HDR, VST and the primary provider, as
# test/live/encounter_save_behoenpc_live_test.rb sends); the flows file CPTs on
# it. Visit 4 (DFN 4) is the build's seeded historical visit, which the build
# no longer lets anyone change. Run on a fresh throwaway container.
Procedure = RpmsRpc::Procedure
DFN = 990_054
VISIT = {} # the visit setup files, for the flows

SETUP = lambda do |client|
  RpmsRpc.configure { |cfg| cfg.client = client }
  clinic = RpmsRpc::DdrFileman.lister(file: "44", fields: ".01", flags: "IP", from: "DEMO PRIMARY CAR",
                                      part: "DEMO PRIMARY CARE", max: "1")[:entries].first.fetch(:ien)
  now = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s[0, 12]
  pcc = { 1 => "HDR^0^^#{clinic};#{now};A", 2 => "VST^DT^#{now}", 3 => "VST^PT^#{DFN}",
          4 => "VST^HL^#{clinic}", 5 => "VST^VC^A", 6 => "PRV^#{client.duz}^^^^1" }
  reply = Array(client.call_rpc("BEHOENPC SAVE", pcc, "0", clinic))
  abort "setup: BEHOENPC SAVE answered #{reply.inspect}" unless reply == [ "0" ]
  rows = RpmsRpc::DdrFileman.lister(file: "9000010.06", fields: ".01;.02;.03", flags: "IP", max: "*")[:entries]
  mine = rows.select { |e| e[:pieces][0] == client.duz.to_s && e[:pieces][1] == DFN.to_s }
  abort "setup: no V PROVIDER for DUZ #{client.duz} on DFN #{DFN}" if mine.empty?
  VISIT[:ien] = mine.last[:pieces][2]
  RpmsRpc.reset!
  {}
end

CAPTURE = {
  rpc: "BEHOENPC SAVE", entry_point: "SAVE^BEHOENPC",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a fresh throwaway container. Setup files today's visit for synthetic DFN 990054 at DEMO PRIMARY CARE; " \
        "CPT A0021 is in the build's CPT file and NOTACPT is not. DFN 990055 is another synthetic patient.",
  setup: SETUP,
  flows: {
    "add" => { about: "add: CPT A0021, quantity 2, on DFN 990054's visit from setup",
               run: -> { Procedure.add(DFN, VISIT.fetch(:ien), "A0021", quantity: 2) } },
    "add_again" => { about: "add: CPT A0021 again on the same visit, after add; its rows after list both, for the " \
                            "unit test that replays them against add's rows before (another session's add in between)",
                     run: -> { Procedure.add(DFN, VISIT.fetch(:ien), "A0021", quantity: 2) } },
    "add_unresolved_cpt" => { about: "add: CPT NOTACPT, which the build cannot resolve, on the same visit",
                              run: -> { Procedure.add(DFN, VISIT.fetch(:ien), "NOTACPT") } },
    "add_wrong_patient" => { about: "add: the same visit, named with DFN 990055, whose it is not",
                             run: -> { Procedure.add(990_055, VISIT.fetch(:ien), "A0021") } },
    "add_visit_not_found" => { about: "add: visit 999999, not on file",
                               run: -> { Procedure.add(DFN, 999_999, "A0021") } },
    "add_locked_visit" => { about: "add: CPT A0021 on the build's historical visit 4 (DFN 4)",
                            run: -> { Procedure.add(4, 4, "A0021") } }
  }
}.freeze
