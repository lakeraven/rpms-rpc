# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for the allergy-symptom catalog. Drives the order-entry
  # allergy-precheck UI.
  # Underlying RPCs: ORWDAL32 SYMPTOMS, ORWDAL32 DEF.
  module Symptom
    extend self

    def search(query)
      return [] if blank?(query)

      Array(DataMapper.symptom_search.fetch_many(query.to_s))
    end

    def defaults
      Array(DataMapper.symptom_defaults.fetch_many)
    end

    private

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
