# frozen_string_literal: true

module RpmsRpc
  module Eligibility
    extend self

    NIL_ELIGIBILITY = { code: nil, label: nil }.freeze

    def for_patient(dfn)
      return NIL_ELIGIBILITY if dfn.nil? || dfn.to_s.empty?

      DataMapper.vfc_eligibility.fetch_one(dfn.to_s) || NIL_ELIGIBILITY
    end

    def codes
      DataMapper.vfc_eligibility_list.fetch_many
    end
  end
end
