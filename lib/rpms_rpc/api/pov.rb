# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for visit purpose-of-visit (POV) entry — visit-level diagnosis
  # codes with optional modifiers (primary/secondary, injury cause, etc.).
  # Underlying RPC: BGOVPOV SET (SET^BGOVPOV — BGOVPOV.m:291).
  module Pov
    extend self

    # Add a POV to an open visit.
    #
    # INP layout (BGOVPOV.m:285-286; parsed :298-303): VPOV IEN[1]^
    # Visit IEN[2]^Problem IEN[3]^Patient IEN[4]^Prov Text[5]^
    # Descriptive CT[6]^SNOMED CT[7]^ICD code[8]^Primary/Secondary[9]^
    # Provider IEN[10]^asthma[11]^norm/abn[12]^laterality[13]^fracture[14].
    # The injury-cause diagnosis rides the separate INJ formal, piece 1
    # (BGOVPOV.m:288,291).
    #
    # Recognized modifiers: :primary/:secondary (piece 9), :problem_ien (3),
    # :descriptive_ct (6), :snomed_ct (7), :provider_duz (10), :laterality
    # (13), :fracture (14), :injury_cause (INJ piece 1).
    def add(dfn, visit_ien, diagnosis_code, narrative:, modifiers: {})
      return failure if invalid_id?(dfn) || invalid_id?(visit_ien) || blank?(diagnosis_code)

      diagnosis_role =
        if modifiers[:primary] then "P"
        elsif modifiers[:secondary] then "S"
        else ""
        end

      inp = [
        "",                             # VPOV IEN — empty for a new entry
        visit_ien.to_s,
        modifiers[:problem_ien].to_s,
        dfn.to_s,
        narrative.to_s,
        modifiers[:descriptive_ct].to_s,
        modifiers[:snomed_ct].to_s,
        diagnosis_code.to_s,
        diagnosis_role,
        modifiers[:provider_duz].to_s,
        "",                             # asthma control
        "",                             # norm/abn (also a NORM formal)
        modifiers[:laterality].to_s,
        modifiers[:fracture].to_s
      ].join("^")
      inj = modifiers[:injury_cause].to_s

      raw = DataMapper.pov_set.fetch_scalar(inp, "", inj)

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
