# frozen_string_literal: true

require "rpms_rpc/api/image"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/server_clock"

# ORWRA IMAGING EXAMS1 (EXAMS1^ORWRA) as Image.exams_for_patient asks for it,
# on a throwaway container. No demo patient has a radiology exam, so setup
# files one for DFN 990001 with DDR FILER, as test/live/image_exams_live_test.rb
# does: RAD/NUC MED PATIENT (#70), REGISTERED EXAMS (#70.02, IEN = the inverse
# exam date), EXAMINATIONS (#70.03, case 12345, ABDOMEN 1 VIEW, EXAMINED).
# It leaves the exam on the container. rpms-rpc#766.
EXAM_DFN = "990001"

CAPTURE = {
  rpc: "ORWRA IMAGING EXAMS1", entry_point: "EXAMS1^ORWRA",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Setup files one radiology exam for DFN #{EXAM_DFN} at the server's NOW: case 12345, procedure " \
        "ABDOMEN 1 VIEW (#71), GENERAL RADIOLOGY, status EXAMINED, no report.",
  setup: lambda { |session|
    RpmsRpc.configure { |cfg| cfg.client = session }
    now = RpmsRpc::FilemanDateParser.format_datetime(RpmsRpc::ServerClock.now)
    at = now[/\A\d{7}(\.\d{1,4})?/].sub(/\.?0+\z/, "")
    inverse = format("%.4f", 9_999_999.9999 - at.to_f).sub(/\.?0+\z/, "")
    procedure = RpmsRpc::DdrFileman.lister(file: "71", fields: "@;.01", flags: "IP", part: "ABDOMEN 1 VIEW", xref: "B")[:entries]
                                   .find { |e| e[:pieces].first == "ABDOMEN 1 VIEW" }.fetch(:ien)
    division = RpmsRpc::DdrFileman.lister(file: "79", fields: "@;.01", flags: "IP", max: "1")[:entries].first.fetch(:ien)
    values = [ [ "70", ".01", "+1,", EXAM_DFN ], [ "70", ".04", "+1,", "O" ],
               [ "70.02", ".01", "+2,+1,", at ], [ "70.02", "2", "+2,+1,", "1" ], [ "70.02", "3", "+2,+1,", division ],
               [ "70.03", ".01", "+3,+2,+1,", "12345" ], [ "70.03", "2", "+3,+2,+1,", procedure ], [ "70.03", "3", "+3,+2,+1,", "4" ] ]
    rows = values.map { |file, field, iens, value| { file: file, field: field, iens: iens, value: value } }
    filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows, iens: { 1 => EXAM_DFN, 2 => inverse })
    abort "setup: DDR FILER could not file the exam: #{filed.inspect}" unless filed && filed[:success]
    RpmsRpc.reset!
    {}
  },
  flows: {
    "exams" => { about: "Image.exams_for_patient of DFN #{EXAM_DFN}, which has the one exam setup filed",
                 run: -> { RpmsRpc::Image.exams_for_patient(EXAM_DFN) } },
    "no_exams" => { about: "Image.exams_for_patient of DFN 4, which has no radiology exam",
                    run: -> { RpmsRpc::Image.exams_for_patient("4") } }
  }
}.freeze
