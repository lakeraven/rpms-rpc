# frozen_string_literal: true

# IHS/RPMS-specific capability features (B* namespaces that exist only on
# RPMS installs). These stay in rpms-rpc after the vista-rpc extraction;
# loaded via `require "rpms_rpc/server_capabilities"` — see
# ../server_capabilities.rb.
module RpmsRpc
  module ServerCapabilities
    # Patient.brief_header — chart-banner projection.
    # Requires the IHS Behavioral Health Suite (BEHO* namespace).
    #
    # Each routine's second formal is DFN, read before anything else:
    # PTINFO(DATA,DFN,SLCT) quits unless ^DPT(+DFN,0) exists (BEHOPTCX.m:7-10),
    # GETBDP(RET,DFN) hands DFN to ALLDP^BDPAPI (BEHOPTPC.m:73-75), and
    # CWAD(DATA,DFN) to CWADX (BEHOCACV.m:22-23). Probed with DFN "0" — no
    # such patient — each answers an empty reply instead of dying on an
    # undefined DFN (verified live on a built 9.0 YottaDB image, #259).
    register(:patient_chart_banner, [
      "BEHOPTCX PTINFO",
      "BEHOPTPC GETBDP",
      "BEHOCACV CWAD"
    ], probe: {
      "BEHOPTCX PTINFO" => [ "0" ],
      "BEHOPTPC GETBDP" => [ "0" ],
      "BEHOCACV CWAD" => [ "0" ]
    })

    # Referral/RCIS workflows — IHS BMC package. Probe with a read-only
    # reference-data RPC only; create/update/status/print calls are writes or
    # can have side effects, so API methods gate them by this association.
    register(:bmc_referral_workflow, [
      "BMC GET REFERENCE DATA"
    ])
  end
end
