# frozen_string_literal: true

module RpmsRpc
  module Vital
    extend self

    def for_patient(dfn)
      DataMapper.vitals.fetch_many(dfn.to_s)
    end
  end
end
