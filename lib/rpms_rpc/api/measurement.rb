# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for PCC measurement entry — distinct from clinical vitals
  # (Vital module / BEHOVM). Measurements are typed observations (height,
  # weight, BMI, head circumference, etc.) recorded against an open encounter.
  # Units should be UCUM codes (e.g. "kg", "cm", "kg/m2") where the
  # downstream consumer needs interoperable units.
  # Underlying RPC: BGOVUPD SET with MSR record type.
  module Measurement
    extend self

    RECORD_TYPE = "MSR"

    def add(dfn, visit_ien, measurement_type, value, units:, qualifier: nil)
      return failure if invalid_id?(dfn) || invalid_id?(visit_ien) ||
                        blank?(measurement_type) || blank?(units) || value.nil?

      payload = [ RECORD_TYPE, measurement_type, value.to_s, units, qualifier.to_s ].join("^")
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
