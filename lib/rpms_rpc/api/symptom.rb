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

    # Parse the ORWDAL32 DEF typed tree into
    #   [ { category: <name>, items: [ { code:, label: }, ... ] }, ... ]
    def defaults
      text = DataMapper.symptom_defaults.fetch_text
      return [] if text.nil? || text.empty?

      categories = []
      current = nil
      text.each_line do |raw|
        line = raw.chomp
        case line[0]
        when "~"
          categories << current if current
          current = { category: line[1..].to_s, items: [] }
        when "i"
          next unless current
          code, label = line[1..].to_s.split("^", 2)
          current[:items] << { code: code.to_s, label: label.to_s }
        end
      end
      categories << current if current
      categories
    end

    private

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
