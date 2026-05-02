# frozen_string_literal: true

module RpmsRpc
  module Encounter
    extend self

    def for_patient(dfn)
      DataMapper.patient_appointments.fetch_many(dfn.to_s)
    end
  end
end
