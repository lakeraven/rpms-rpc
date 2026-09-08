# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for visit exam-component entry — structured physical-exam
  # findings (skin, neuro, etc.) recorded against an open encounter.
  # Underlying RPC: BGOVEXAM SET (SET^BGOVEXAM — BGOVEXAM.m:106).
  module ExamComponent
    extend self

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
    end

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
