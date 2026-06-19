# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/client"
require "rpms_rpc/cia_client"
require "rpms_rpc/server_capabilities"

class RpmsRpc::ServerCapabilitiesTest < Minitest::Test
  # Minimal probing client: records each call_rpc, raises on a configured
  # set of "missing" RPCs (mimicking what a real Broker returns when an
  # RPC is not registered to the current OPTION or the package isn't
  # installed).
  class ProbingClient
    attr_reader :calls

    def initialize(missing: [])
      @missing = missing
      @calls = []
    end

    def call_rpc(rpc_name, *_params)
      @calls << rpc_name
      if @missing.include?(rpc_name)
        raise RpmsRpc::Client::RpcError, "Remote Procedure '#{rpc_name}' doesn't exist"
      end
      ""
    end
  end

  def setup
    @client = ProbingClient.new
  end

  # -- Feature registry sanity ------------------------------------------------

  def test_patient_chart_banner_feature_is_registered
    assert RpmsRpc::ServerCapabilities::FEATURE_RPCS.key?(:patient_chart_banner),
           "Registry must expose :patient_chart_banner — the immediate consumer is Patient.brief_header"
  end

  def test_patient_chart_banner_maps_to_beho_rpcs
    rpcs = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:patient_chart_banner]
    assert_includes rpcs, "BEHOPTCX PTINFO"
    assert_includes rpcs, "BEHOPTPC GETBDP"
    assert_includes rpcs, "BEHOCACV CWAD"
  end

  def test_user_security_keys_list_feature_is_registered
    assert RpmsRpc::ServerCapabilities::FEATURE_RPCS.key?(:user_security_keys_list),
           "Registry must expose :user_security_keys_list — gates Authentication#user_security_keys / UserManagement#security_keys"
  end

  def test_user_security_keys_list_maps_to_orwu_userkeys
    rpcs = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:user_security_keys_list]
    assert_equal [ "ORWU USERKEYS" ], rpcs
  end

  def test_probe_returns_false_when_orwu_userkeys_missing
    missing = ProbingClient.new(missing: [ "ORWU USERKEYS" ])
    assert_equal false, RpmsRpc::ServerCapabilities.probe(missing, :user_security_keys_list)
  end

  def test_health_summary_gmts_feature_is_registered
    assert RpmsRpc::ServerCapabilities::FEATURE_RPCS.key?(:health_summary_gmts),
           "Registry must expose :health_summary_gmts — gates HealthSummary GMTS-namespace RPCs"
  end

  def test_health_summary_gmts_maps_to_gmts_cluster
    rpcs = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:health_summary_gmts]
    assert_includes rpcs, "GMTS PWH REPORT"
    assert_includes rpcs, "GMTS FLOWSHEET LIST"
    assert_includes rpcs, "GMTS FLOWSHEET DATA"
    assert_includes rpcs, "GMTS MAINT ITEMS"
  end

  def test_probe_returns_false_when_any_gmts_rpc_missing
    missing = ProbingClient.new(missing: [ "GMTS FLOWSHEET DATA" ])
    assert_equal false, RpmsRpc::ServerCapabilities.probe(missing, :health_summary_gmts)
  end

  def test_xu_key_admin_feature_is_registered
    assert RpmsRpc::ServerCapabilities::FEATURE_RPCS.key?(:xu_key_admin),
           "Registry must expose :xu_key_admin — gates UserManagement list_all_keys / grant_key / revoke_key"
  end

  def test_xu_key_admin_probes_read_only_xu_key_list
    rpcs = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:xu_key_admin]
    assert_equal [ "XU KEY LIST" ], rpcs,
                 "Probe set must be read-only; XU KEY GRANT/REVOKE are writes and gate-by-association"
  end

  def test_probe_returns_false_when_xu_key_list_missing
    missing = ProbingClient.new(missing: [ "XU KEY LIST" ])
    assert_equal false, RpmsRpc::ServerCapabilities.probe(missing, :xu_key_admin)
  end

  def test_pso_prescription_orders_feature_is_registered
    assert RpmsRpc::ServerCapabilities::FEATURE_RPCS.key?(:pso_prescription_orders),
           "Registry must expose :pso_prescription_orders — gates Eprescribing.transmit / status / cancel"
  end

  def test_pso_prescription_orders_probes_pso_erx_status
    rpcs = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:pso_prescription_orders]
    assert_equal [ "PSO ERX STATUS" ], rpcs,
                 "Probe set picks PSO ERX STATUS as the read-leaning sentinel; PSO NEW RX / CANCEL RX gate by association"
  end

  def test_probe_returns_false_when_pso_erx_status_missing
    missing = ProbingClient.new(missing: [ "PSO ERX STATUS" ])
    assert_equal false, RpmsRpc::ServerCapabilities.probe(missing, :pso_prescription_orders)
  end

  def test_xqal_alert_actions_feature_is_registered
    assert RpmsRpc::ServerCapabilities::FEATURE_RPCS.key?(:xqal_alert_actions),
           "Registry must expose :xqal_alert_actions — gates Communication get_alerts / mark_alert_read / forward_alert"
  end

  def test_xqal_alert_actions_probes_xqal_new_alerts
    rpcs = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:xqal_alert_actions]
    assert_equal [ "XQAL NEW ALERTS" ], rpcs,
                 "Read-only sentinel; XQAL MARK READ / FORWARD writes gate by association"
  end

  def test_probe_returns_false_when_xqal_new_alerts_missing
    missing = ProbingClient.new(missing: [ "XQAL NEW ALERTS" ])
    assert_equal false, RpmsRpc::ServerCapabilities.probe(missing, :xqal_alert_actions)
  end

  def test_bphr_phr_endpoints_feature_is_registered
    assert RpmsRpc::ServerCapabilities::FEATURE_RPCS.key?(:bphr_phr_endpoints),
           "Registry must expose :bphr_phr_endpoints — gates Phr patient/provider/facility direct + record_access"
  end

  def test_bphr_phr_endpoints_probes_bphr_patient_direct
    rpcs = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:bphr_phr_endpoints]
    assert_equal [ "BPHR PATIENT DIRECT" ], rpcs,
                 "Read-only sentinel; BPHR RECORD ACCESS write gates by association"
  end

  def test_probe_returns_false_when_bphr_patient_direct_missing
    missing = ProbingClient.new(missing: [ "BPHR PATIENT DIRECT" ])
    assert_equal false, RpmsRpc::ServerCapabilities.probe(missing, :bphr_phr_endpoints)
  end

  def test_orwlrr_lab_reports_feature_is_registered
    assert RpmsRpc::ServerCapabilities::FEATURE_RPCS.key?(:orwlrr_lab_reports),
           "Registry must expose :orwlrr_lab_reports — gates Lab for_patient / reports / find"
  end

  def test_orwlrr_lab_reports_probes_all_three_rpcs
    rpcs = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:orwlrr_lab_reports]
    assert_includes rpcs, "ORWLRR RESULT LIST"
    assert_includes rpcs, "ORWLRR REPORT LIST"
    assert_includes rpcs, "ORWLRR REPORT"
  end

  def test_probe_returns_false_when_any_orwlrr_rpc_missing
    missing = ProbingClient.new(missing: [ "ORWLRR REPORT" ])
    assert_equal false, RpmsRpc::ServerCapabilities.probe(missing, :orwlrr_lab_reports)
  end

  def test_orwra_radiology_reports_feature_is_registered
    assert RpmsRpc::ServerCapabilities::FEATURE_RPCS.key?(:orwra_radiology_reports),
           "Registry must expose :orwra_radiology_reports — gates Radiology for_patient / find"
  end

  def test_orwra_radiology_reports_probes_both_rpcs
    rpcs = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:orwra_radiology_reports]
    assert_includes rpcs, "ORWRA REPORT"
    assert_includes rpcs, "ORWRA REPORT LIST"
  end

  def test_probe_returns_false_when_any_orwra_rpc_missing
    missing = ProbingClient.new(missing: [ "ORWRA REPORT" ])
    assert_equal false, RpmsRpc::ServerCapabilities.probe(missing, :orwra_radiology_reports)
  end

  def test_orwpce_clinical_logs_feature_is_registered
    assert RpmsRpc::ServerCapabilities::FEATURE_RPCS.key?(:orwpce_clinical_logs),
           "Registry must expose :orwpce_clinical_logs — gates Device for_patient / find + Procedure for_patient"
  end

  def test_orwpce_clinical_logs_probes_live_caller_rpcs
    rpcs = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:orwpce_clinical_logs]
    assert_includes rpcs, "ORWPCE IMPLANT LIST"
    assert_includes rpcs, "ORWPCE IMPLANT GET"
    assert_includes rpcs, "ORWPCE PROCEDURE LIST"
  end

  def test_probe_returns_false_when_any_orwpce_rpc_missing
    missing = ProbingClient.new(missing: [ "ORWPCE PROCEDURE LIST" ])
    assert_equal false, RpmsRpc::ServerCapabilities.probe(missing, :orwpce_clinical_logs)
  end

  def test_orwrp_report_types_feature_is_registered
    assert RpmsRpc::ServerCapabilities::FEATURE_RPCS.key?(:orwrp_report_types),
           "Registry must expose :orwrp_report_types — gates HealthSummary types / type_components"
  end

  def test_orwrp_report_types_probes_both_rpcs
    rpcs = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:orwrp_report_types]
    assert_includes rpcs, "ORWRP TYPES"
    assert_includes rpcs, "ORWRP TYPE COMPONENTS"
  end

  def test_probe_returns_false_when_any_orwrp_rpc_missing
    missing = ProbingClient.new(missing: [ "ORWRP TYPE COMPONENTS" ])
    assert_equal false, RpmsRpc::ServerCapabilities.probe(missing, :orwrp_report_types)
  end

  def test_bmc_referral_workflow_feature_is_registered
    assert RpmsRpc::ServerCapabilities::FEATURE_RPCS.key?(:bmc_referral_workflow),
           "Registry must expose :bmc_referral_workflow — gates Referral BMC/RCIS RPCs"
  end

  def test_bmc_referral_workflow_probes_read_only_reference_data
    rpcs = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:bmc_referral_workflow]
    assert_equal [ "BMC GET REFERENCE DATA" ], rpcs,
                 "Probe set must avoid BMC referral write/print/status RPCs"
  end

  def test_probe_returns_false_when_bmc_reference_data_missing
    missing = ProbingClient.new(missing: [ "BMC GET REFERENCE DATA" ])
    assert_equal false, RpmsRpc::ServerCapabilities.probe(missing, :bmc_referral_workflow)
  end

  def test_orqqpl_problem_workflow_feature_is_registered
    assert RpmsRpc::ServerCapabilities::FEATURE_RPCS.key?(:orqqpl_problem_workflow),
           "Registry must expose :orqqpl_problem_workflow — gates Problem ORQQPL lookup/mutation RPCs"
  end

  def test_orqqpl_problem_workflow_probes_read_only_detail
    rpcs = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:orqqpl_problem_workflow]
    assert_equal [ "ORQQPL DETAIL" ], rpcs,
                 "Probe set must avoid ORQQPL write RPCs (ADD SAVE, EDIT SAVE, DELETE, INACTIVATE, VERIFY, REPLACE, UPDATE)"
  end

  def test_probe_returns_false_when_orqqpl_detail_missing
    missing = ProbingClient.new(missing: [ "ORQQPL DETAIL" ])
    assert_equal false, RpmsRpc::ServerCapabilities.probe(missing, :orqqpl_problem_workflow)
  end

  def test_unknown_feature_raises_argument_error
    assert_raises(ArgumentError) do
      RpmsRpc::ServerCapabilities.probe(@client, :no_such_feature)
    end
  end

  # -- Probe behavior ---------------------------------------------------------

  def test_probe_returns_true_when_all_feature_rpcs_callable
    assert_equal true, RpmsRpc::ServerCapabilities.probe(@client, :patient_chart_banner)
  end

  def test_probe_returns_false_when_any_feature_rpc_missing
    missing = ProbingClient.new(missing: [ "BEHOPTPC GETBDP" ])
    assert_equal false, RpmsRpc::ServerCapabilities.probe(missing, :patient_chart_banner)
  end

  def test_probe_returns_false_for_noline_signature
    raising = Class.new do
      def call_rpc(*)
        raise RpmsRpc::Client::RpcError, "M  ERROR=<NOLINE>PTINFO+22 BEHOPTCX"
      end
    end.new
    assert_equal false, RpmsRpc::ServerCapabilities.probe(raising, :patient_chart_banner)
  end

  def test_probe_treats_other_rpc_errors_as_rpc_present
    # An RPC that raises with a non-"missing" signature (e.g., parameter
    # validation, runtime error) is still installed — capability is true.
    other = Class.new do
      def call_rpc(*)
        raise RpmsRpc::Client::RpcError, "M  ERROR=<UNDEFINED>FOO+5^XYZ^"
      end
    end.new
    assert_equal true, RpmsRpc::ServerCapabilities.probe(other, :patient_chart_banner)
  end

  # -- Client#supports? caches ------------------------------------------------
  #
  # Production code paths must not re-probe on every call. One round of
  # probing per feature per client lifetime.

  def test_client_supports_caches_after_first_probe
    cia = RpmsRpc::CiaClient.new
    def cia.call_rpc(rpc_name, *_params)
      @probe_calls ||= 0
      @probe_calls += 1
      ""
    end
    def cia.probe_call_count = (@probe_calls || 0)

    3.times { cia.supports?(:patient_chart_banner) }

    # Feature has 3 RPCs; expect each probed exactly once across all 3 calls
    expected = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:patient_chart_banner].size
    assert_equal expected, cia.probe_call_count
  end

  def test_client_supports_returns_cached_false_without_reprobing
    cia = RpmsRpc::CiaClient.new
    raise_count = { n: 0 }
    cia.define_singleton_method(:call_rpc) do |_name, *_params|
      raise_count[:n] += 1
      raise RpmsRpc::Client::RpcError, "Remote Procedure 'X' doesn't exist"
    end

    refute cia.supports?(:patient_chart_banner)
    refute cia.supports?(:patient_chart_banner)
    refute cia.supports?(:patient_chart_banner)

    # First probe hits the first RPC, fails, short-circuits → only 1 call.
    # Cached false → no more calls on subsequent supports? invocations.
    assert_equal 1, raise_count[:n]
  end

  # -- Cache invalidation ------------------------------------------------------
  #
  # The cache must not survive across connection or context boundaries: a
  # different Broker, or even the same Broker under a different OPTION, can
  # answer the same probe differently. Stale "true" → broken short-circuit
  # to a missing RPC; stale "false" → never-resurrected capability.

  def test_reset_connection_clears_capability_cache
    cia = RpmsRpc::CiaClient.new
    probe_count = { n: 0 }
    cia.define_singleton_method(:call_rpc) do |_name, *_params|
      probe_count[:n] += 1
      ""
    end

    assert cia.supports?(:patient_chart_banner)
    assert cia.supports?(:patient_chart_banner)
    feature_size = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:patient_chart_banner].size
    assert_equal feature_size, probe_count[:n], "second supports? must be cached"

    cia.send(:reset_connection)

    assert cia.supports?(:patient_chart_banner)
    assert_equal feature_size * 2, probe_count[:n],
                 "reset_connection must invalidate the cache so re-probe happens"
  end

  def test_create_context_clears_capability_cache
    cia = RpmsRpc::CiaClient.new
    cia.define_singleton_method(:connected?) { true }
    cia.define_singleton_method(:authenticated?) { true }
    probe_count = { n: 0 }
    cia.define_singleton_method(:call_rpc) do |_name, *_params|
      probe_count[:n] += 1
      ""
    end
    # Stub the context-creation call so create_context succeeds without
    # going to the wire; the assertion is purely about cache state.
    cia.define_singleton_method(:call_rpc_raw) { |_, *_| "1" }

    assert cia.supports?(:patient_chart_banner)
    feature_size = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:patient_chart_banner].size
    assert_equal feature_size, probe_count[:n]

    cia.create_context("OR CPRS GUI CHART")

    assert cia.supports?(:patient_chart_banner)
    assert_equal feature_size * 2, probe_count[:n],
                 "create_context must invalidate the cache because RPC " \
                 "registration is OPTION-scoped"
  end

  def test_open_socket_clears_capability_cache_for_implicit_reconnect
    # Several network error paths only flip @connected = false without
    # going through reset_connection. A caller can then re-enter
    # open_socket against the same or a different Broker with stale
    # capability answers still cached. The fix: clear the cache at the
    # top of open_socket itself.
    cia = RpmsRpc::CiaClient.new
    cia.instance_variable_set(:@capability_cache, { patient_chart_banner: true })

    # Force open_socket's TCPSocket.new to raise; the cache must already
    # be cleared by the time the exception bubbles out.
    TCPSocket.stub(:new, ->(*) { raise Errno::ECONNREFUSED }) do
      assert_raises(RpmsRpc::Client::ConnectionError) do
        cia.send(:open_socket, "localhost", 9100)
      end
    end

    assert_nil cia.instance_variable_get(:@capability_cache),
               "open_socket must clear capability cache on entry so a " \
               "reconnect after a half-dead connection can't reuse stale answers"
  end
end
