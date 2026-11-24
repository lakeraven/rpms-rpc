# frozen_string_literal: true

require "rpms_rpc/api/lab"
require "rpms_rpc/api/ddr_fileman"

# RpmsRpc::Lab.results stepping ORWLRR INTERIMG over a date range, as
# PROVIDER,TEST (rpms-rpc#732). The build files no LAB DATA (#63), so setup
# files five chemistry specimens for the synthetic patient DFN 990031 with
# DDR FILER: a #63 entry (LRDFN = DFN, PARENT FILE 2), the patient's #2
# field 63 LABORATORY REFERENCE, and #63.04 specimens on BLOOD (#61 70),
# each with a POC GLUCOSE (#60 2096016, data name 7819007) result and one
# with a COVID-19 (#60 2096008, data name 7819001) result. Four carry a
# DATE REPORT COMPLETED, released at noon, at 9:12 AM (a one-digit hour,
# rpms-rpc#844) and with no time; the 3261105 one does not, so INTERIMG
# skips it.
# FileMan files the value only: the normalcy flag (piece 2) is LRVER's to
# write, so these results carry no flag.
LAB_DFN = 990_031

SPECIMENS = [
  { collected: "3261110.0915", accession: "CH 1110 2", glucose: "96", covid: "N", completed: "3261110.12" },
  { collected: "3261107.1", accession: "CH 1107 2", glucose: "101", completed: "3261107" },
  { collected: "3261105.1", accession: "CH 1105 4", glucose: "120" },
  { collected: "3261103.083", accession: "CH 1103 1", glucose: "142", completed: "3261103.0912" },
  { collected: "3260901.1", accession: "CH 0901 3", glucose: "210", completed: "3260901.12" }
].freeze

def file_lab_data(session)
  RpmsRpc.configure { |cfg| cfg.client = session }
  fm = RpmsRpc::DdrFileman
  top = [ [ ".01", LAB_DFN ], [ ".02", 2 ], [ ".03", LAB_DFN ] ].map { |f, v| { file: "63", field: f, iens: "+1,", value: v.to_s } }
  steps = [ fm.filer(mode: "ADD", rows: top, iens: { 1 => LAB_DFN }),
            fm.filer(mode: "EDIT", rows: [ { file: "2", field: "63", iens: "#{LAB_DFN},", value: LAB_DFN.to_s } ]) ]
  SPECIMENS.each do |s|
    fields = { ".01" => s[:collected], ".03" => s[:completed], ".04" => 200, ".05" => 70, ".06" => s[:accession],
               ".1" => 200, "7819007" => s[:glucose], "7819001" => s[:covid] }.compact
    rows = fields.map { |f, v| { file: "63.04", field: f, iens: "+1,#{LAB_DFN},", value: v.to_s } }
    inverse = format("%.4f", 9_999_999 - s[:collected].to_r).sub(/\.?0+\z/, "")
    steps << fm.filer(mode: "ADD", rows: rows, iens: { 1 => inverse })
  end
  abort "setup: DDR FILER did not file the lab data: #{steps.inspect}" unless steps.all? { |r| r&.dig(:success) }
  {}
ensure
  RpmsRpc.reset!
end

CAPTURE = {
  rpc: "ORWLRR INTERIMG", entry_point: "INTERIMG^ORWLRR",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair; DUZ 200)",
  access: "PROV123", verify: "PROV123!!",
  context: "CIAV VUECENTRIC",
  note: "Run on a throwaway container. Setup files five synthetic chemistry specimens for DFN 990031 through " \
        "DDR FILER (#63, #2 field 63, #63.04): 3261110.0915 POC GLUCOSE 96 and COVID-19 Negative (completed 3261110.12), " \
        "3261107.1 POC GLUCOSE 101 (completed 3261107, no time), 3261105.1 POC GLUCOSE 120 with no DATE REPORT " \
        "COMPLETED, 3261103.083 POC GLUCOSE 142 (completed 3261103.0912), 3260901.1 POC GLUCOSE 210. " \
        "FileMan files no normalcy flag. DFN 4 has no LAB DATA.",
  setup: ->(session) { file_lab_data(session) },
  flows: {
    "in_range" => { about: "results(990031, from: 2026-10-01, to: 2026-11-19): three released specimens (at noon, " \
                           "with no time, at 9:12 AM), the unverified one skipped, the 2026-09-01 one read and left out",
                    run: -> { RpmsRpc::Lab.results(LAB_DFN, from: Date.new(2026, 10, 1), to: Date.new(2026, 11, 19)) } },
    "no_lab_data" => { about: "results(4, ...): a patient with no LAB DATA",
                       run: -> { RpmsRpc::Lab.results(4, from: Date.new(2026, 10, 1), to: Date.new(2026, 11, 19)) } },
    "specimen_default" => { about: "specimen(990031) with no from: (rpms-rpc#840): the newest released specimen, " \
                                   "asked from tomorrow",
                            run: -> { RpmsRpc::Lab.specimen(LAB_DFN) } },
    "specimen_no_lab_data" => { about: "specimen(4) with no from:: a patient with no LAB DATA",
                                run: -> { RpmsRpc::Lab.specimen(4) } }
  }
}.freeze
