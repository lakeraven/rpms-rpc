# frozen_string_literal: true

# Stock-VistA capability features (kernel + clinical namespaces that exist
# on any VistA). Bucketed here ahead of the vista-rpc extraction; loaded
# via `require "rpms_rpc/server_capabilities"` — see ../server_capabilities.rb.
#
# Every RPC a feature probes must be registered on a pinned registry
# (test/rpms_rpc/registered_rpc_names_test.rb). The nine stock features
# that once lived here probed names no built 9.0 image registers
# (ORWU USERKEYS, GMTS *, XU KEY LIST, PSO ERX STATUS, XQAL NEW ALERTS,
# ORWLRR REPORT*/RESULT LIST, ORWRA REPORT*, ORWPCE IMPLANT*/PROCEDURE LIST,
# ORWRP TYPES/TYPE COMPONENTS) and were removed with their callers (#207).
module RpmsRpc
  module ServerCapabilities
    # ORQQPL problem-list mutation + lookup surface — stock VistA.
    # Probe with a read-only RPC only; ADD SAVE, EDIT SAVE, DELETE,
    # INACTIVATE, VERIFY, REPLACE, UPDATE are writes and must not be
    # invoked just to test capability.
    #
    # ORQQPL INIT PT, not ORQQPL DETAIL: INITPT(RETURN,DFN)^ORQQPL1 quits
    # on +$G(DFN)=0 (ORQQPL1.m:214-215), so a parameterless probe answers
    # empty. DETAIL(Y,DFN,PROBIEN,ID) has no safe synthetic input: without
    # a real problem IEN it dies in M on PROBIEN, or on the detail array
    # DETAIL^GMPLUTL2 never built — which is what every Problem lookup
    # logged as "DETAIL+3^ORQQPL undefined PROBIEN" before it ran (#259).
    register(:orqqpl_problem_workflow, [
      "ORQQPL INIT PT"
    ])
  end
end
