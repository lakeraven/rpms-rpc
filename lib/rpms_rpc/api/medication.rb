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
    #
    # Formals: LIST(ORY,ORPT,ORSTRTDT,ORSTOPDT) (ORQQPS.m:4). Both dates go
    # over the wire, empty: the routine hands them straight to
    # OCL^PSOORRL, which reads $G(BDT)/$G(EDT) and starts the list 120 days
    # back when the start is empty (PSOORRL.m:13-15). A frame with only the
    # DFN left ORSTRTDT undefined and the call died in M (#259).
    def for_patient(dfn)
      return [] if dfn.nil? || dfn.to_s.strip.empty? || dfn.to_i <= 0

      DataMapper.medication_list.fetch_many(dfn.to_s, "", "").reject { |r| r[:id].to_s.empty? }
    end

    def find(ien)
      return nil if ien.nil? || ien.to_i <= 0

      DataMapper.medication_detail.fetch_text(ien.to_s)
    end
  end
end
