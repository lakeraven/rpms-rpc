# frozen_string_literal: true

module RpmsRpc
  module Procedure
    extend self

    def for_patient(dfn)
      DataMapper.procedure_list.fetch_many(dfn.to_s)
    end
  end
end
