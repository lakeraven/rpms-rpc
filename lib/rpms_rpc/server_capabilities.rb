# frozen_string_literal: true

module RpmsRpc
  # Server-side capability detection. Distinct from `RpmsRpc::Capabilities`,
  # which is user-permission focused (security keys, role-based access).
  # This module answers "is this RPC installed and callable on the Broker?"
  #
  # Engine code asks by symbolic feature name, never by RPC name:
  #
  #   RpmsRpc.client.supports?(:patient_chart_banner)
  #
  # Detection is a per-RPC probe (call with no params; the Broker reports
  # "RPC doesn't exist" / "<NOLINE>" before any param validation runs).
  # ALL FEATURES REGISTERED HERE MUST RESOLVE TO READ-ONLY RPCS — probing
  # would otherwise have side effects on write paths.
  #
  # Results are cached on the client instance via `Client#supports?`, so
  # each feature is probed at most once per session.
  module ServerCapabilities
    FEATURE_RPCS = {
      # Patient.brief_header — chart-banner projection.
      # Requires the IHS Behavioral Health Suite (BEHO* namespace).
      patient_chart_banner: [
        "BEHOPTCX PTINFO",
        "BEHOPTPC GETBDP",
        "BEHOCACV CWAD"
      ].freeze,

      # Authentication#user_security_keys / UserManagement#security_keys —
      # list of security keys held by a user. ORWU USERKEYS is absent on
      # the 2026-06-07 staging dump; callers should gate via supports? and
      # fall back to per-key probes (ORWU HASKEY) when unsupported.
      user_security_keys_list: [
        "ORWU USERKEYS"
      ].freeze,

      # HealthSummary — GMTS-namespace health summary, flowsheet, and
      # maintenance-items reads. The GMTS package is absent entirely on
      # the 2026-06-07 staging dump (zero entries on file 8994); callers
      # should gate via supports? and skip the read when unsupported.
      health_summary_gmts: [
        "GMTS PWH REPORT",
        "GMTS FLOWSHEET LIST",
        "GMTS FLOWSHEET DATA",
        "GMTS MAINT ITEMS"
      ].freeze,

      # UserManagement#list_all_keys / #grant_key / #revoke_key — XU KEY
      # namespace is absent entirely on the 2026-06-07 staging dump. Probe
      # via the read-only XU KEY LIST; the GRANT/REVOKE writes gate by
      # association so an unsupported broker never receives them.
      xu_key_admin: [
        "XU KEY LIST"
      ].freeze,

      # Eprescribing#transmit / #status / #cancel — PSO namespace is absent
      # entirely on the 2026-06-07 staging dump (no PSO entries on file
      # 8994). Probe via PSO ERX STATUS as the read-leaning sentinel; PSO
      # NEW RX and PSO CANCEL RX are clinical writes and gate by association
      # so an unsupported broker never receives them.
      pso_prescription_orders: [
        "PSO ERX STATUS"
      ].freeze,

      # Communication#get_alerts / #mark_alert_read / #forward_alert —
      # XQAL NEW ALERTS, MARK READ, and FORWARD are all absent on the
      # 2026-06-07 staging dump. (Only XQAL GUI ALERTS is present; that's
      # a different CPRS-GUI-format read API the gem doesn't currently
      # consume — re-routing is a separate concern.) Probe via XQAL NEW
      # ALERTS as the read sentinel; the MARK READ / FORWARD writes gate
      # by association.
      xqal_alert_actions: [
        "XQAL NEW ALERTS"
      ].freeze,

      # Phr#patient_direct_address / #provider_direct_address /
      # #facility_direct_domain / #record_access — BPHR namespace is
      # absent entirely on the 2026-06-07 staging dump. Probe via the
      # read-shape BPHR PATIENT DIRECT; the BPHR RECORD ACCESS write
      # (logs PHR access for reporting) gates by association.
      bphr_phr_endpoints: [
        "BPHR PATIENT DIRECT"
      ].freeze,

      # Lab#for_patient / #reports / #find — ORWLRR RESULT LIST,
      # ORWLRR REPORT LIST, and ORWLRR REPORT are all absent on the
      # 2026-06-07 staging dump (the ORWLRR namespace IS installed, with
      # entries like INTERIM / ATOMICS / SPEC — just not the three the
      # gem consumes). All three are reads, so probe all three: a server
      # could have one but not the others (sentinel pattern would risk a
      # false positive). Same cluster-probe shape as :patient_chart_banner
      # and :health_summary_gmts.
      orwlrr_lab_reports: [
        "ORWLRR RESULT LIST",
        "ORWLRR REPORT LIST",
        "ORWLRR REPORT"
      ].freeze,

      # Radiology#for_patient / #find — ORWRA REPORT and ORWRA REPORT
      # LIST are absent on the 2026-06-07 staging dump (the ORWRA
      # namespace has ORWRA REPORT TEXT / REPORT TEXT1 — possible rename
      # situation worth follow-up investigation). Both gem-consumed RPCs
      # are reads, so probe both per the all-reads cluster pattern.
      orwra_radiology_reports: [
        "ORWRA REPORT",
        "ORWRA REPORT LIST"
      ].freeze,

      # Device#for_patient / #find + Procedure#for_patient — ORWPCE
      # IMPLANT LIST/GET and ORWPCE PROCEDURE LIST are absent on the
      # 2026-06-07 staging dump (the ORWPCE namespace IS installed with
      # DIAG / PROC / VISIT / IMM / etc. — just not the IMPLANT/PROCEDURE
      # log variants the gem consumes). Probe all three live-consumer
      # RPCs (cluster-probe, all-reads). procedure_detail's ORWPCE
      # PROCEDURE GET has no live caller and isn't probed.
      orwpce_clinical_logs: [
        "ORWPCE IMPLANT LIST",
        "ORWPCE IMPLANT GET",
        "ORWPCE PROCEDURE LIST"
      ].freeze
    }.freeze

    # RPC error messages that indicate the RPC itself is not installed
    # or not registered to the current OPTION. Anything else means the
    # RPC IS present (it ran far enough to raise a different error).
    MISSING_RPC_PATTERN = /<NOLINE>|Remote Procedure .* (?:doesn't exist|not found)/i

    # Probe whether `client` can call all RPCs backing `feature`.
    # Short-circuits on first missing RPC.
    def self.probe(client, feature)
      rpcs = FEATURE_RPCS[feature]
      raise ArgumentError, "Unknown capability feature: #{feature.inspect}" unless rpcs

      rpcs.all? { |rpc| rpc_present?(client, rpc) }
    end

    def self.rpc_present?(client, rpc_name)
      client.call_rpc(rpc_name)
      true
    rescue RpmsRpc::Client::RpcError => e
      !e.message.match?(MISSING_RPC_PATTERN)
    end
  end
end
