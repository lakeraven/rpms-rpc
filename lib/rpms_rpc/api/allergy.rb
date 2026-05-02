# frozen_string_literal: true

module RpmsRpc
  module Allergy
    extend self

    def for_patient(dfn)
      DataMapper.allergy_list.fetch_many(dfn.to_s)
    end
  end
end
