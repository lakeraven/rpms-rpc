# frozen_string_literal: true

module RpmsRpc
  # Symbolic API for VFC/VFA eligibility codes.
  # Underlying RPCs (BIPC family): ELIGGET, ELIGLIST.
  #
  # Returns plain hashes: { code:, label: }. NIL_ELIGIBILITY for invalid /
  # unknown DFN; an empty result array for codes() when the list RPC returns
  # nothing.
  module Eligibility
    extend self

    NIL_ELIGIBILITY = { code: nil, label: nil }.freeze

    def for_patient(dfn)
      return NIL_ELIGIBILITY if dfn.nil? || dfn.to_s.empty? || dfn.to_i <= 0

      DataMapper.vfc_eligibility.fetch_one(dfn.to_s) || NIL_ELIGIBILITY
    end

    def codes
      Array(DataMapper.vfc_eligibility_list.fetch_many)
    end
  end
end
