# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for visit procedures (CPT codes). Read via ORWPCE PROCEDURE GET
  # (single) and procedure_list (multi); write via BGOVCPT SET.
  module Procedure
    extend self

    def for_patient(dfn)
      DataMapper.procedure_list.fetch_many(dfn.to_s)
    end

    def add(dfn, visit_ien, cpt_code, modifiers: [], narrative: nil, quantity: 1)
      return failure if invalid_id?(dfn) || invalid_id?(visit_ien) || blank?(cpt_code)

      modifier_str = Array(modifiers).join(",")
      payload = [ cpt_code, modifier_str, narrative.to_s, quantity.to_i ].join("^")
      raw = DataMapper.procedure_save.fetch_scalar(dfn.to_s, visit_ien.to_s, payload)

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
