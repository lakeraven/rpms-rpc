# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for recording a patient's refusal of an immunization on
  # the open encounter. Distinct from {RpmsRpc::Immunization}, which is
  # read-only.
  # Underlying RPC: BGOREP SET.
  module ImmunizationRefusal
    extend self

    # Standard reason taxonomy. Wire codes are best-effort placeholders
    # pending wider trace capture; if the codes change, only this table
    # needs updating. Public API uses symbols.
    REASON_CODES = {
      parental: "P",
      religious: "R",
      medical_contraindication: "M",
      patient_preference: "X",
      other: "O"
    }.freeze

    def record(dfn, vaccine_code, reason_code:, narrative: nil)
      return failure if invalid_id?(dfn) || blank?(vaccine_code)

      code = REASON_CODES[reason_code]
      raise ArgumentError, "unknown reason_code: #{reason_code.inspect}" if code.nil?

      payload = [ vaccine_code, code, narrative.to_s ].join("^")
      raw = DataMapper.immunization_refusal_save.fetch_scalar(dfn.to_s, payload)

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
