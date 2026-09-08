# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for PCC measurement entry — distinct from clinical vitals
  # (Vital module / BEHOVM). Measurements are typed observations (height,
  # weight, BMI, head circumference, etc.) recorded against an open encounter.
  # Underlying RPC: BGOVMSR SET (SET^BGOVMSR — BGOVMSR.m:105).
  module Measurement
    extend self

    # Add a measurement to an open visit.
    #
    # INP layout (BGOVMSR.m:104; parsed :108-118): Visit IEN[1]^
    # V File IEN[2]^Type[3]^Value[4]^Date/Time[5]. Type accepts the AUTTMSR
    # abbreviation (e.g. "WT", "HT") — non-numeric values resolve through
    # the "B" cross-reference (BGOVMSR.m:115). Returns the saved
    # V MEASUREMENT IEN (BGOVMSR.m:139).
    #
    # The wire carries NO units piece: units are fixed by the measurement
    # type definition (MEASUREMENT TYPE #9999999.07), so the value must
    # already be in the type's native unit (e.g. WT in lbs, HT in inches).
    # The units: keyword documents the caller's intent and is validated as
    # present, but cannot be transmitted; likewise qualifier has no wire
    # target and is not sent.
    def add(dfn, visit_ien, measurement_type, value, units:, qualifier: nil)
      return failure if invalid_id?(dfn) || invalid_id?(visit_ien) ||
                        blank?(measurement_type) || blank?(units) || value.nil?

      inp = [
        visit_ien.to_s,
        "",                    # V File IEN — empty for a new entry
        measurement_type.to_s,
        value.to_s,
        ""                     # date/time — defaults to visit date (BGOVMSR.m:132)
      ].join("^")
      raw = DataMapper.measurement_set.fetch_scalar(inp)

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
