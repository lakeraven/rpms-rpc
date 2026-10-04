# frozen_string_literal: true

require "date"
require_relative "../mappings"

module RpmsRpc
  # Symbolic API for visit procedures (CPT codes). Read via BGOVCPT GET;
  # write via BGOVCPT SET.
  #
  # `for_patient` once sent ORWPCE PROCEDURE LIST, a name no built image
  # registers (#207). It is kept, rebuilt on BGOVCPT GET (GET^BGOVCPT), the
  # V CPT read VueCentric's procedure component uses.
  module Procedure
    extend self

    # The patient's V CPT entries, one hash per entry:
    #   :ien (V CPT IEN), :visit_ien, :date (the visit date, a Date),
    #   :cpt_code, :cpt_name, :name (the provider narrative, or the CPT name
    #   when none was filed), :diagnosis, :modifier_1, :modifier_2
    #   (CODE~NAME), :quantity, :provider (name), :facility.
    # V CPT carries no status, so there is no :status key. A refused or
    # failed read raises; an empty list means none on file.
    def for_patient(dfn)
      return [] if invalid_id?(dfn)

      DataMapper.procedure_list.fetch_many(dfn.to_s).map do |row|
        row.merge(date: visit_date(row[:date]))
      end
    end

    def add(dfn, visit_ien, cpt_code, modifiers: [], narrative: nil, quantity: 1)
      return failure if invalid_id?(dfn) || invalid_id?(visit_ien) || blank?(cpt_code)
      return failure if quantity.nil? || quantity.to_i <= 0

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

    # $$FMTDATE^BGOUTL writes the visit date as MM/DD/YYYY (BGOUTL.m:373-377).
    def visit_date(value)
      Date.strptime(value.to_s, "%m/%d/%Y")
    rescue Date::Error
      nil
    end

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
