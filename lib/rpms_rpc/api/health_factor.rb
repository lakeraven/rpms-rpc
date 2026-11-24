# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"

module RpmsRpc
  # Symbolic API for visit health-factor entry — IHS-specific structured
  # observations (tobacco use, food security, social risk, etc.) with an
  # optional severity level.
  # Underlying RPCs: BGOVHF GET (GET^BGOVHF — BGOVHF.m:8), BGOVHF SET
  # (SET^BGOVHF — BGOVHF.m:45).
  module HealthFactor
    extend self
    extend Shape::Declarable

    # The health factors recorded for a patient, as VueCentric's Health
    # Factors component lists them: BGOVHF GET (GET^BGOVHF), grouped by
    # factor, newest visit first.
    #
    #   for_patient(dfn, learn_only: false)
    #     => [{ category:, factor:, visit_date:, severity:, quantity:,
    #           visit_ien:, ien:, factor_ien:, comment:, visit_locked:,
    #           event_date:, start_date:, end_date: }, ...]
    #
    # ien is the V HEALTH FACTORS (#9000010.23) IEN; the dates are Dates.
    # learn_only: true keeps the learning-readiness factors only
    # ($$ISLEARN^BGOVHF). A -n^text reply raises Client::RpcError.
    def for_patient(dfn, learn_only: false)
      return [] if invalid_id?(dfn)

      DataMapper.patient_health_factors.fetch_many!("#{dfn}^#{learn_only ? 1 : ''}^")
    end
    shape :for_patient, resource: "health-factors", verb: "GET", path: "/patients/{dfn}/health-factors"

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
    rescue RpmsRpc::Client::FrameTooLongError => e
      # A value the wire would mis-frame is refused before anything is sent
      # (#472); the failure shape says why instead of raising.
      failure.merge(error: e.message)
    end
    shape :add, resource: "health-factors", verb: "POST", path: "/patients/{dfn}/health-factors"

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
