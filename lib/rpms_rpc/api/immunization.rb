# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for patient immunization records.
  #
  # Underlying RPC: BEHOCIR GETTXT (text_summary), the CCD patient-summary
  # text blob. The structured list/detail reads this module once offered
  # (`for_patient`, `find`) sent BIPC IMMLIST / BIPC IMMGET, names no built
  # 9.0 image registers; they were removed (#207). The registered IHS
  # immunization surface is BGOVIMM* (V IMMUNIZATION writes) and BYIM *
  # (the state-registry exchange); model those from the registry and the
  # routines before adding a structured read back (ADR 0003).
  module Immunization
    extend self

    # The CCD patient-summary text blob (BEHOCIR GETTXT).
    def text_summary(dfn)
      return nil if invalid_id?(dfn)

      DataMapper.immunization_text.fetch_text(dfn.to_s)
    end

    private

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
