# frozen_string_literal: true

module RpmsRpc
  module Medication
    extend self

    # ORQQPS LIST date params (LIST^ORQQPS: ORSTRTDT/ORSTOPDT, FileMan
    # dates). Both are required on the wire — omitting them raises the M
    # error "Undefined local variable: ORSTRTDT". Blank dates return the
    # current medication profile (OCL^PSOORRL defaults).
    def for_patient(dfn, start_date: "", stop_date: "")
      DataMapper.medication_list.fetch_many(dfn.to_s, start_date.to_s, stop_date.to_s)
    end

    def find(ien)
      return nil if ien.nil? || ien.to_i <= 0

      DataMapper.medication_detail.fetch_text(ien.to_s)
    end
  end
end
