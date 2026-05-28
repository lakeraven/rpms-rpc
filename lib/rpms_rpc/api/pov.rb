# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for visit purpose-of-visit (POV) entry — visit-level diagnosis
  # codes with optional modifiers (primary/secondary, injury cause, etc.).
  # Underlying RPC: BGOVUPD SET with POV record type.
  module Pov
    extend self

    RECORD_TYPE = "POV"

    def add(dfn, visit_ien, diagnosis_code, narrative:, modifiers: {})
      return failure if invalid_id?(dfn) || invalid_id?(visit_ien) || blank?(diagnosis_code)

      diagnosis_role =
        if modifiers[:primary] then "P"
        elsif modifiers[:secondary] then "S"
        else ""
        end

      payload = [
        RECORD_TYPE,
        diagnosis_code,
        narrative.to_s,
        diagnosis_role,
        modifiers[:injury_cause].to_s,
        modifiers[:fraction].to_s
      ].join("^")

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
