# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for visit health-factor entry — IHS-specific structured
  # observations (tobacco use, food security, social risk, etc.) with an
  # optional severity level.
  # Underlying RPC: BGOVUPD SET with HF record type.
  module HealthFactor
    extend self

    RECORD_TYPE = "HF"

    def add(dfn, visit_ien, factor_code, level:, narrative: nil)
      return failure if invalid_id?(dfn) || invalid_id?(visit_ien) || blank?(factor_code)

      payload = [ RECORD_TYPE, factor_code, level.to_s, narrative.to_s ].join("^")
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
