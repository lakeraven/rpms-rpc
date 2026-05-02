# frozen_string_literal: true

module RpmsRpc
  module VFC
    extend self

    def eligibility(dfn)
      DataMapper.vfc_eligibility.fetch_one(dfn.to_s) || { code: nil, label: nil }
    end

    def eligibility_codes
      DataMapper.vfc_eligibility_list.fetch_many
    end
  end
end
