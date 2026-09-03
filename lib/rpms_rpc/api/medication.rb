# frozen_string_literal: true

module RpmsRpc
  module Medication
    extend self

    # Condensed medication list. Underlying RPC: ORQQPS LIST — verified
    # row shape ID^NAME^STOP_DATE^ROUTE^SCHEDULE^REFILLS (LIST^ORQQPS:
    # ORQQPS.m:4-55; see the :medication_list mapping). "No medications"
    # comes back as the sentinel row "^No medications found."
    # (ORQQPS.m:53) — no id, so it is dropped rather than surfaced as a
    # phantom medication. Invalid DFNs short-circuit to [] without
    # dispatching an RPC.
    def for_patient(dfn)
      return [] if dfn.nil? || dfn.to_s.strip.empty? || dfn.to_i <= 0

      DataMapper.medication_list.fetch_many(dfn.to_s).reject { |r| r[:id].to_s.empty? }
    end

    def find(ien)
      return nil if ien.nil? || ien.to_i <= 0

      DataMapper.medication_detail.fetch_text(ien.to_s)
    end
  end
end
