# frozen_string_literal: true

module RpmsRpc
  module Immunization
    extend self

    def for_patient(dfn)
      DataMapper.immunization_text.fetch_text(dfn.to_s)
    end
  end
end
