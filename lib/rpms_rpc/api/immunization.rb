# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for patient-administered immunization records.
  #
  # Underlying RPCs:
  #   - BIPC IMMLIST: patient-scoped administered record list
  #   - BIPC IMMGET:  single administered record by IEN
  #   - BEHOCIR GETTXT (text_summary): the CCD patient-summary text blob
  #
  # Wire field positions for IMMLIST / IMMGET are best-effort pending
  # wider trace capture; if the positions change, only :immunization_list
  # and :immunization_detail in mappings.rb need updating.
  module Immunization
    extend self

    def for_patient(dfn)
      return [] if invalid_id?(dfn)

      Array(DataMapper.immunization_list.fetch_many(dfn.to_s))
    end

    def find(ien)
      return nil if invalid_id?(ien)

      DataMapper.immunization_detail.fetch_one(ien.to_s)
    end

    # The CCD patient-summary text blob (BEHOCIR GETTXT). Kept under a
    # distinct accessor so callers that want the summary text don't have
    # to compete with the structured list shape on `for_patient`.
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
