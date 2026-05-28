# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for visit exam-component entry — structured physical-exam
  # findings (skin, neuro, etc.) recorded against an open encounter.
  # Underlying RPC: BGOVUPD SET with EXAM record type.
  module ExamComponent
    extend self

    RECORD_TYPE = "EXAM"

    def add(dfn, visit_ien, exam_code, finding:, narrative: nil)
      return failure if invalid_id?(dfn) || invalid_id?(visit_ien) || blank?(exam_code) || blank?(finding)

      payload = [ RECORD_TYPE, exam_code, finding.to_s, narrative.to_s ].join("^")
      raw = DataMapper.visit_data_save.fetch_scalar(dfn.to_s, visit_ien.to_s, payload)

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
