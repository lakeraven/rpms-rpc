# frozen_string_literal: true

require "rpms_rpc/api/vital"
require "rpms_rpc/api/vital_stock"
require "rpms_rpc/api/ddr_fileman"

# The conversations RpmsRpc::Vital.add_stock has with the build over stock
# VistA GMV GET VITAL TYPE IEN, GMV EXTRACT REC and GMV ADD VM (rpms-rpc#458,
# #621), recorded as flows as PROVIDER,TEST on a fresh throwaway container, in
# order. The flows file vitals for synthetic DFN 990054 at DEMO PRIMARY CARE
# at fixed times, so the record each test builds is the one recorded; the
# second BP, the same reading, is taken at the same second as the first, so
# its read-back sees the first row before the save. The GMV RPCs run under
# OR CPRS GUI CHART, which PROVIDER,TEST holds; the live spec signs on as the
# same pair.
# test/live/vital_add_stock_live_test.rb proves the save against the
# server's clock.
Vital = RpmsRpc::Vital
DFN = 990_054
DUZ = 200
TAKEN = Time.new(2026, 11, 19, 9, 30, 15)
LATER = Time.new(2026, 11, 19, 10, 15, 0)
CLINIC = {} # DEMO PRIMARY CARE's IEN, which setup reads

SETUP = lambda do |client|
  RpmsRpc.configure { |cfg| cfg.client = client }
  clinic = RpmsRpc::DdrFileman.lister(file: "44", fields: ".01", flags: "IP", from: "DEMO PRIMARY CAR",
                                      part: "DEMO PRIMARY CARE", max: "1")[:entries].first.fetch(:ien)
  abort "setup: expected DEMO PRIMARY CARE at location 10, found #{clinic.inspect}" unless clinic == "10"
  CLINIC[:ien] = Integer(clinic)
  RpmsRpc.reset!
  {}
end

def save(measurements, taken_at)
  -> { Vital.add_stock(DFN, measurements, location_ien: CLINIC.fetch(:ien), entered_by_duz: DUZ, taken_at: taken_at) }
end

CAPTURE = {
  rpc: "GMV ADD VM", entry_point: "EN1^GMVDCSAV",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair; DUZ 200)",
  access: "PROV123", verify: "PROV123!!",
  note: "Run on a fresh throwaway container, flows in order. Vitals for synthetic DFN 990054 at DEMO PRIMARY CARE " \
        "(location 10), entered by DUZ 200, taken at 2026-11-19 09:30:15 unless the flow says otherwise.",
  setup: SETUP,
  flows: {
    "bp" => { about: "add_stock: BP 120/80", run: save([ { abbreviation: "BP", value: "120/80" } ], TAKEN) },
    "bp_same_second" => { about: "add_stock: BP 120/80 again, at the same second as the first BP",
                          run: save([ { abbreviation: "BP", value: "120/80" } ], TAKEN) },
    "weight_qualified" => { about: "add_stock: WT 180 lb, qualifiers 42 (ACTUAL) and 72 (BED)",
                            run: save({ abbreviation: "WT", value: 180, units: "lb", qualifier_iens: [ 42, 72 ] }, TAKEN) },
    "bp_and_pulse" => { about: "add_stock: BP 124/78 and P 72, taken at 2026-11-19 10:15:00",
                        run: save([ { abbreviation: "BP", value: "124/78" }, { abbreviation: "P", value: 72 } ], LATER) }
  }
}.freeze
