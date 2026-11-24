# frozen_string_literal: true

require "rpms_rpc/api/vital"
require "rpms_rpc/api/ddr_fileman"

# The BEHOVM SAVE conversations RpmsRpc::Vital.add has with the build,
# recorded as flows as PROFILE,MD (rpms-rpc#621). Setup files a visit for
# synthetic DFN 990054 today at DEMO PRIMARY CARE with a BEHOENPC SAVE of its
# own (as tools/captured_replies/procedure-add.rb does); the flows file vitals
# on it at a fixed time, so the payload each test builds is the one recorded.
# Run on a fresh throwaway container.
Vital = RpmsRpc::Vital
DFN = 990_054
TAKEN = Time.new(2026, 11, 19, 9, 30, 15)
VISIT = {} # the visit string setup files, for the flows

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
  VISIT[:string] = "#{clinic};#{now};A;#{mine.last[:pieces][2]}"
  RpmsRpc.reset!
  {}
end

CAPTURE = {
  rpc: "BEHOVM SAVE", entry_point: "SAVE^BEHOVM",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a fresh throwaway container. Setup files today's visit for synthetic DFN 990054 at DEMO PRIMARY CARE; " \
        "the flows file vitals on it, taken at 2026-11-19 09:30:15.",
  setup: SETUP,
  flows: {
    "add" => { about: "add: TMP 97 F, PU 80 /min and BP 130/90 mmHg on the visit from setup",
               run: lambda {
                 Vital.add(DFN, VISIT.fetch(:string), [ { abbreviation: "TMP", value: 97, units: "F" },
                                                        { abbreviation: "PU", value: 80, units: "/min" },
                                                        { abbreviation: "BP", value: "130/90", units: "mmHg" } ],
                           provider_duz: 206, taken_at: TAKEN)
               } },
    "add_one" => { about: "add: one measurement given as a hash, not a list: TMP 98 F on the same visit",
                   run: lambda {
                     Vital.add(DFN, VISIT.fetch(:string), { abbreviation: "TMP", value: 98, units: "F" },
                               provider_duz: 206, taken_at: TAKEN)
                   } },
    "add_refused" => { about: "add: TMP 999 F, out of range, on the same visit: the build stores nothing",
                       run: lambda {
                         Vital.add(DFN, VISIT.fetch(:string), [ { abbreviation: "TMP", value: 999, units: "F" } ],
                                   provider_duz: 206, taken_at: TAKEN)
                       } }
  }
}.freeze
