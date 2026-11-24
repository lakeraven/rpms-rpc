# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"
require_relative "ddr_fileman"

module RpmsRpc
  # Symbolic API for visit exam-component entry — structured physical-exam
  # findings (skin, neuro, etc.) recorded against an open encounter.
  # Underlying RPCs: BGOVEXAM GET (GET^BGOVEXAM — BGOVEXAM.m:14), BGOVEXAM
  # SET (SET^BGOVEXAM — BGOVEXAM.m:106).
  module ExamComponent
    extend self
    extend Shape::Declarable

    # The exams recorded for a patient, as VueCentric's Exam component lists
    # them: BGOVEXAM GET (GET^BGOVEXAM), newest visit first per exam type.
    #
    #   for_patient(dfn) => { exams: [{ exam:, visit_date:, result:, comment:,
    #                                   provider_name:, facility:, provider_ien:,
    #                                   location_ien:, exam_ien:, ien:, visit_ien:,
    #                                   service_category:, visit_locked:,
    #                                   event_date: }, ...],
    #                         refusals: ["R^...", ...] }
    #
    # ien is the V EXAM (#9000010.13) IEN; the dates are Dates. Refusals
    # (REFGET^BGOUTL2) are the rows as the build sent them: the pinned build
    # carries no exam refusal to check their pieces against. A -n^text reply
    # raises Client::RpcError rather than reading as "no exams".
    def for_patient(dfn)
      return { exams: [], refusals: [] } if invalid_id?(dfn)

      lines = DataMapper.patient_exams.lines!(dfn.to_s)
      exams = lines.select { |line| line.start_with?("E^") }
      { exams: DataMapper.patient_exams.parse_many(exams).map { |row| row.except(:kind) },
        refusals: lines.select { |line| line.start_with?("R^") } }
    end
    shape :for_patient, resource: "exam-components", verb: "GET", path: "/patients/{dfn}/exam-components"

    # Add an exam result to an open visit.
    #
    # INP layout (BGOVEXAM.m:103-104; parsed :109-129): V Exam IEN[1]^
    # Exam IEN[2]^Visit IEN[3]^Provider IEN[4]^Result[5]^Comment[6]^
    # Event Date[7]^Location IEN[8]^Other Location[9]^Historical[10]^DFN[11].
    # exam_code is the EXAM (#9999999.15) type IEN; finding is the Result
    # value ("NORMAL"/"NEGATIVE" normalize to "N" server-side —
    # BGOVEXAM.m:124). An empty provider defaults to the signed-on DUZ
    # (BGOVEXAM.m:121). Returns the saved V EXAM IEN (BGOVEXAM.m:156).
    def add(dfn, visit_ien, exam_code, finding:, narrative: nil, provider_duz: nil)
      return failure if invalid_id?(dfn) || invalid_id?(visit_ien) || blank?(exam_code) || blank?(finding)

      inp = [
        "",                 # V Exam IEN — empty for a new entry
        exam_code.to_s,
        visit_ien.to_s,
        provider_duz.to_s,
        finding.to_s,
        narrative.to_s,
        "",                 # event date — defaults to NOW (BGOVEXAM.m:126-127)
        "",                 # location IEN (historical entries only)
        "",                 # other location (historical entries only)
        "",                 # historical flag
        dfn.to_s
      ].join("^")
      raw = DataMapper.exam_set.fetch_scalar(inp)

      saved_ien = raw.to_s.match(/\A\d+/)&.to_s&.to_i
      {
        success: !saved_ien.nil? && saved_ien.positive?,
        ien: saved_ien,
        raw: raw
      }
    rescue RpmsRpc::Client::FrameTooLongError => e
      # A value the wire would mis-frame is refused before anything is sent
      # (#472); the failure shape says why instead of raising.
      failure.merge(error: e.message)
    end
    shape :add, resource: "exam-components", verb: "POST", path: "/patients/{dfn}/exam-components"

    # EXAM file (#9999999.15, ^AUTTEXAM).
    EXAM_FILE = "9999999.15"

    # Every exam type on file, inactive ones included and flagged, so a code
    # system can still resolve a historical code (rpms-rpc#917):
    #
    #   types => [{ ien:, code:, name:, inactive: }, ...]
    #
    # code is CODE (.02, "01"), name NAME (.01), inactive INACTIVE FLAG
    # (.04) = 1. ClinicalEvent.exam_types (ORWPCE GET EXAM TYPE) lists only
    # the active ones, without their codes. Read through DDR LISTER; a read
    # that cannot be had whole raises Client::RpcError.
    def types
      DdrFileman.list_all(file: EXAM_FILE, fields: "@;.02;.01;.04").map do |entry|
        code, name, inactive = entry[:pieces]
        { ien: entry[:ien].to_i, code: code.to_s, name: name.to_s, inactive: inactive == "1" }
      end
    end
    shape :types, resource: "exam-components", verb: "GET", path: "/exam-components/types"

    private

    def failure
      { success: false, ien: nil, raw: nil }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
