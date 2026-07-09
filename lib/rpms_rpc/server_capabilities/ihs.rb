# frozen_string_literal: true

# IHS/RPMS-specific capability features (B* namespaces that exist only on
# RPMS installs). These stay in rpms-rpc after the vista-rpc extraction;
# loaded via `require "rpms_rpc/server_capabilities"` — see
# ../server_capabilities.rb.
module RpmsRpc
  module ServerCapabilities
    # Patient.brief_header — chart-banner projection.
    # Requires the IHS Behavioral Health Suite (BEHO* namespace).
    register(:patient_chart_banner, [
      "BEHOPTCX PTINFO",
      "BEHOPTPC GETBDP",
      "BEHOCACV CWAD"
    ])

    # Phr#patient_direct_address / #provider_direct_address /
    # #facility_direct_domain / #record_access — BPHR namespace is
    # absent entirely on the 2026-06-07 staging dump. Probe via the
    # read-shape BPHR PATIENT DIRECT; the BPHR RECORD ACCESS write
    # (logs PHR access for reporting) gates by association.
    register(:bphr_phr_endpoints, [
      "BPHR PATIENT DIRECT"
    ])

    # Referral/RCIS workflows — IHS BMC package. Probe with a read-only
    # reference-data RPC only; create/update/status/print calls are writes or
    # can have side effects, so API methods gate them by this association.
    register(:bmc_referral_workflow, [
      "BMC GET REFERENCE DATA"
    ])
  end
end
