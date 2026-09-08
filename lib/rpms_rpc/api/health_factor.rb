# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for visit health-factor entry — IHS-specific structured
  # observations (tobacco use, food security, social risk, etc.) with an
  # optional severity level.
  # Underlying RPC: BGOVHF SET (SET^BGOVHF — BGOVHF.m:45).
  module HealthFactor
    extend self

    # Add a health factor to an open visit.
    #
    # INP layout (BGOVHF.m:44; parsed :48-56,:68): HF Type IEN[1]^
    # V File IEN[2]^Visit IEN[3]^Severity[4]^Provider IEN[5]^Quantity[6]^
    # Comment[7]^Event dt[8]. factor_code is the HEALTH FACTOR (#9999999.64)
    # type IEN — the routine reads it numerically (TYPE=+INP — BGOVHF.m:48).
    # The patient is implied by the visit; dfn is validated but not on the
    # wire. Returns the saved V HEALTH FACTOR IEN (BGOVHF.m:83).
    def add(dfn, visit_ien, factor_code, level:, narrative: nil, provider_duz: nil, quantity: nil)
      return failure if invalid_id?(dfn) || invalid_id?(visit_ien) || blank?(factor_code)

      inp = [
        factor_code.to_s,
        "",                 # V File IEN — empty for a new entry
        visit_ien.to_s,
        level.to_s,
        provider_duz.to_s,
        quantity.to_s,
        narrative.to_s
      ].join("^")
      raw = DataMapper.health_factor_set.fetch_scalar(inp)

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
