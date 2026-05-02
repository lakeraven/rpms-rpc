# frozen_string_literal: true

module RpmsRpc
  module Medication
    extend self

    def for_patient(dfn)
      DataMapper.medication_list.fetch_many(dfn.to_s)
    end

    def find(ien)
      return nil if ien.nil? || ien.to_i <= 0

      DataMapper.medication_detail.fetch_text(ien.to_s)
    end
  end
end
