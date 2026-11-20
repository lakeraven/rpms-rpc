# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/image"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/server_clock"

# Image.exams_for_patient reads ORWRA IMAGING EXAMS1 (EXAMS1^ORWRA). GET^ORWRA
# writes each exam as SITE ^ EXAM ID ^ (9999999.9999-ID) ^ the EN1^RAO7PC1 row
# (procedure ^ case number ^ report status ^ abnormal alert ^ ...), with SITE
# "name;station" because EXAMS1 asks for it (ORWRA.m, GET; RAO7PC1A.m, SETDATA).
#
# No demo patient has a radiology exam, so the spec files one with DDR FILER:
# a RAD/NUC MED PATIENT (#70) entry, a REGISTERED EXAMS (#70.02) entry whose
# IEN is the inverse exam date, and an EXAMINATIONS (#70.03) case. Internal
# values, as a seed files them: the input transforms (CN^RAREG1, ^RASTREQ) are
# for the interactive registration. It deletes what it filed. rpms-rpc#766.
class ImageExamsLiveTest < LiveSpec::Test
  runs_as "PROV123"
  writes!

  DFN = "990001"
  RAD_PATIENT = "70"
  GENERAL_RADIOLOGY = "1" # TYPE OF IMAGING #79.2
  EXAMINED = "4"          # EXAM STATUS #72: order 2, GENERAL RADIOLOGY; not WAITING, which RAO7PC1A skips without an order
  PROCEDURE_NAME = "ABDOMEN 1 VIEW"

  def test_an_exam_row_reads_in_the_order_the_routine_writes_it
    exam = file_exam
    begin
      rows = RpmsRpc::Image.exams_for_patient(DFN)
      row = rows.find { |r| r[:exam_id] == exam[:exam_id] }
      refute_nil row, "the filed exam #{exam[:exam_id]} is not among #{rows.inspect}"

      assert_match(/\A[^;^]+;\d+\z/, row[:site], "SITE is name;station")
      # The same instant: FileMan drops a time's trailing zeros (.183 is 18:30), the parse does not.
      assert_equal RpmsRpc::FilemanDateParser.parse_datetime(exam[:datetime]), row[:datetime]
      assert_equal PROCEDURE_NAME, row[:procedure]
      assert_equal exam[:case_number], row[:case_number]
      assert_equal "No Report", row[:status], "no report is filed for the exam"
      assert_nil row[:abnormal], "no diagnostic code, so no abnormal alert"
      puts "\n#{persona}: exam #{row[:exam_id]} read back as #{row.inspect}"
    ensure
      remove_exam
    end
  end

  private

  def file_exam
    flunk "DFN #{DFN} already has a RAD/NUC MED PATIENT entry; remove it from the container first" if rad_patient?
    at = RpmsRpc::FilemanDateParser.format_datetime(RpmsRpc::ServerClock.now)
    datetime = at[/\A\d{7}(\.\d{1,4})?/].sub(/\.?0+\z/, "")
    inverse = format("%.4f", 9_999_999.9999 - datetime.to_f).sub(/\.?0+\z/, "")
    case_number = rand(10_000..99_999).to_s
    rows = [
      { file: RAD_PATIENT, field: ".01", iens: "+1,", value: DFN },
      { file: RAD_PATIENT, field: ".04", iens: "+1,", value: "O" },
      { file: "70.02", field: ".01", iens: "+2,+1,", value: datetime },
      { file: "70.02", field: "2", iens: "+2,+1,", value: GENERAL_RADIOLOGY },
      { file: "70.02", field: "3", iens: "+2,+1,", value: division },
      { file: "70.03", field: ".01", iens: "+3,+2,+1,", value: case_number },
      { file: "70.03", field: "2", iens: "+3,+2,+1,", value: procedure },
      { file: "70.03", field: "3", iens: "+3,+2,+1,", value: EXAMINED }
    ]
    filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows, iens: { 1 => DFN, 2 => inverse })
    assert filed && filed[:success], "DDR FILER could not file a radiology exam: #{filed.inspect}"
    { exam_id: "#{inverse}-#{filed[:iens].fetch(3)}", datetime: datetime, case_number: case_number }
  end

  def remove_exam
    deleted = RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: [ { file: RAD_PATIENT, field: ".01", iens: "#{DFN},", value: "@" } ])
    assert deleted && deleted[:success], "DDR FILER could not delete RAD/NUC MED PATIENT #{DFN}: #{deleted.inspect}"
    refute rad_patient?, "RAD/NUC MED PATIENT #{DFN} is still on file after the delete"
    assert_empty RpmsRpc::Image.exams_for_patient(DFN), "DFN #{DFN} still lists an exam after the delete"
  end

  def rad_patient?
    entry = RpmsRpc::DdrFileman.gets_entry(file: RAD_PATIENT, iens: "#{DFN},", fields: ".01", flags: "I")
    flunk "DDR GETS ENTRY DATA on file #{RAD_PATIENT} gave no reply" if entry.nil?
    !entry[:error]
  end

  def division
    listed = RpmsRpc::DdrFileman.lister(file: "79", fields: "@;.01", flags: "IP", max: "1")
    found = listed && listed[:entries].first
    flunk "the build has no RAD/NUC MED DIVISION (#79)" unless found
    found[:ien]
  end

  def procedure
    listed = RpmsRpc::DdrFileman.lister(file: "71", fields: "@;.01", flags: "IP", part: PROCEDURE_NAME, xref: "B")
    found = listed && listed[:entries].find { |e| e[:pieces].first == PROCEDURE_NAME }
    flunk "the build has no RAD/NUC MED PROCEDURE named #{PROCEDURE_NAME}" unless found
    found[:ien]
  end
end
