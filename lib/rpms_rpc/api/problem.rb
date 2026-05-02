# frozen_string_literal: true

module RpmsRpc
  module Problem
    extend self

    def for_patient(dfn)
      DataMapper.problem_list.fetch_many(dfn.to_s)
    end
  end
end
