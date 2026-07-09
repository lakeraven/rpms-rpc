# frozen_string_literal: true

# Stock-VistA capability features (kernel + clinical namespaces that exist
# on any VistA). Bucketed here ahead of the vista-rpc extraction; loaded
# via `require "rpms_rpc/server_capabilities"` — see ../server_capabilities.rb.
module RpmsRpc
  module ServerCapabilities
    # Authentication#user_security_keys / UserManagement#security_keys —
    # list of security keys held by a user. ORWU USERKEYS is absent on
    # the 2026-06-07 staging dump; callers should gate via supports? and
    # fall back to per-key probes (ORWU HASKEY) when unsupported.
    register(:user_security_keys_list, [
      "ORWU USERKEYS"
    ])

    # HealthSummary — GMTS-namespace health summary, flowsheet, and
    # maintenance-items reads. The GMTS package is absent entirely on
    # the 2026-06-07 staging dump (zero entries on file 8994); callers
    # should gate via supports? and skip the read when unsupported.
    register(:health_summary_gmts, [
      "GMTS PWH REPORT",
      "GMTS FLOWSHEET LIST",
      "GMTS FLOWSHEET DATA",
      "GMTS MAINT ITEMS"
    ])

    # UserManagement#list_all_keys / #grant_key / #revoke_key — XU KEY
    # namespace is absent entirely on the 2026-06-07 staging dump. Probe
    # via the read-only XU KEY LIST; the GRANT/REVOKE writes gate by
    # association so an unsupported broker never receives them.
    register(:xu_key_admin, [
      "XU KEY LIST"
    ])

    # Eprescribing#transmit / #status / #cancel — PSO namespace is absent
    # entirely on the 2026-06-07 staging dump (no PSO entries on file
    # 8994). Probe via PSO ERX STATUS as the read-leaning sentinel; PSO
    # NEW RX and PSO CANCEL RX are clinical writes and gate by association
    # so an unsupported broker never receives them.
    register(:pso_prescription_orders, [
      "PSO ERX STATUS"
    ])

    # Communication#get_alerts / #mark_alert_read / #forward_alert —
    # XQAL NEW ALERTS, MARK READ, and FORWARD are all absent on the
    # 2026-06-07 staging dump. (Only XQAL GUI ALERTS is present; that's
    # a different CPRS-GUI-format read API the gem doesn't currently
    # consume — re-routing is a separate concern.) Probe via XQAL NEW
    # ALERTS as the read sentinel; the MARK READ / FORWARD writes gate
    # by association.
    register(:xqal_alert_actions, [
      "XQAL NEW ALERTS"
    ])

    # Lab#for_patient / #reports / #find — ORWLRR RESULT LIST,
    # ORWLRR REPORT LIST, and ORWLRR REPORT are all absent on the
    # 2026-06-07 staging dump (the ORWLRR namespace IS installed, with
    # entries like INTERIM / ATOMICS / SPEC — just not the three the
    # gem consumes). All three are reads, so probe all three: a server
    # could have one but not the others (sentinel pattern would risk a
    # false positive). Same cluster-probe shape as :patient_chart_banner
    # and :health_summary_gmts.
    register(:orwlrr_lab_reports, [
      "ORWLRR RESULT LIST",
      "ORWLRR REPORT LIST",
      "ORWLRR REPORT"
    ])

    # Radiology#for_patient / #find — ORWRA REPORT and ORWRA REPORT
    # LIST are absent on the 2026-06-07 staging dump (the ORWRA
    # namespace has ORWRA REPORT TEXT / REPORT TEXT1 — possible rename
    # situation worth follow-up investigation). Both gem-consumed RPCs
    # are reads, so probe both per the all-reads cluster pattern.
    register(:orwra_radiology_reports, [
      "ORWRA REPORT",
      "ORWRA REPORT LIST"
    ])

    # Device#for_patient / #find + Procedure#for_patient — ORWPCE
    # IMPLANT LIST/GET and ORWPCE PROCEDURE LIST are absent on the
    # 2026-06-07 staging dump (the ORWPCE namespace IS installed with
    # DIAG / PROC / VISIT / IMM / etc. — just not the IMPLANT/PROCEDURE
    # log variants the gem consumes). Probe all three live-consumer
    # RPCs (cluster-probe, all-reads). procedure_detail's ORWPCE
    # PROCEDURE GET has no live caller and isn't probed.
    register(:orwpce_clinical_logs, [
      "ORWPCE IMPLANT LIST",
      "ORWPCE IMPLANT GET",
      "ORWPCE PROCEDURE LIST"
    ])

    # HealthSummary#types / #type_components — ORWRP TYPES and
    # ORWRP TYPE COMPONENTS are absent on the 2026-06-07 staging dump.
    # Both are reads, so probe both (cluster-probe pattern). When
    # unsupported, types falls back to DEFAULT_TYPES (existing
    # graceful-degradation pattern); type_components returns [].
    register(:orwrp_report_types, [
      "ORWRP TYPES",
      "ORWRP TYPE COMPONENTS"
    ])

    # ORQQPL problem-list mutation + lookup surface — stock VistA.
    # Probe with a read-only RPC (DETAIL) only; ADD SAVE, EDIT SAVE,
    # DELETE, INACTIVATE, VERIFY, REPLACE, UPDATE are writes and must
    # not be invoked just to test capability.
    register(:orqqpl_problem_workflow, [
      "ORQQPL DETAIL"
    ])
  end
end
