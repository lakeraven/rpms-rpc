# frozen_string_literal: true

# DEPRECATED shim. `RpmsRpc::CiaClient` was a misnomer: it implements the stock XWB
# ([XWB]1130 / XWBTCPM) protocol — what CPRS and every non-IHS VistA speak — NOT the IHS
# CIA {CIA} protocol. It has been renamed RpmsRpc::XwbClient.
#
# This alias keeps `require "rpms_rpc/cia_client"` and `RpmsRpc::CiaClient` working during
# migration. Prefer:
#   - RpmsRpc::XwbClient        — stock VistA / VA / WorldVistA / civilian VistA (XWB)
#   - RpmsRpc::CiaBrokerClient  — IHS RPMS CIA broker (CIANBLIS / VueCentric)
#   - RpmsRpc::BmxClient        — IHS RPMS BMX broker (BMXNet)
# One EHR can target both worlds by configuring the client per deployment; the app code is
# broker-agnostic (all share the ^XWB(8994) RPC registry). Remove this alias in the next major.
require "rpms_rpc/xwb_client"

module RpmsRpc
  CiaClient = XwbClient
end
