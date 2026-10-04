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

  # INITPT^ORQQPL1 quits on +$G(DFN)=0 (ORQQPL1.m:214-215), so it is the one
  # ORQQPL read a parameterless probe can make without dying in M. DETAIL
  # needs a real problem IEN (#259).
  def test_orqqpl_problem_workflow_probes_read_only_init_pt
    rpcs = RpmsRpc::ServerCapabilities::FEATURE_RPCS[:orqqpl_problem_workflow]
    assert_equal [ "ORQQPL INIT PT" ], rpcs,
                 "Probe set must avoid ORQQPL write RPCs (ADD SAVE, EDIT SAVE, DELETE, INACTIVATE, VERIFY, REPLACE, UPDATE)"
  end

  def test_probe_returns_false_when_orqqpl_init_pt_missing
    missing = ProbingClient.new(missing: [ "ORQQPL INIT PT" ])
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

  # The probe frame must carry the formals the routine reads. PTINFO^BEHOPTCX,
  # GETBDP^BEHOPTPC and CWAD^BEHOCACV each read DFN on their first lines
  # (BEHOPTCX.m:7-10, BEHOPTPC.m:73-75, BEHOCACV.m:22-23); probed with no
  # parameters they died in M on every sign-on (#259). DFN "0" names no
  # patient and each answers empty.
  def test_chart_banner_probe_sends_a_dfn_to_each_beho_rpc
    recording = Class.new do
      attr_reader :frames
      def initialize = @frames = []
      def call_rpc(rpc_name, *params)
        @frames << [ rpc_name, params ]
        ""
      end
    end.new

    RpmsRpc::ServerCapabilities.probe(recording, :patient_chart_banner)

    assert_equal [ [ "BEHOPTCX PTINFO", [ "0" ] ], [ "BEHOPTPC GETBDP", [ "0" ] ], [ "BEHOCACV CWAD", [ "0" ] ] ],
                 recording.frames
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
    # Make open_socket's TCP connect raise; the cache must already be
    # cleared by the time the exception bubbles out.
    refusing = Class.new(RpmsRpc::CiaClient) do
      def connect_tcp(*) = raise(Errno::ECONNREFUSED)
    end
    cia = refusing.new
    cia.instance_variable_set(:@capability_cache, { patient_chart_banner: true })

    assert_raises(RpmsRpc::Client::ConnectionError) do
      cia.send(:open_socket, "localhost", 9100)
    end

    assert_nil cia.instance_variable_get(:@capability_cache),
               "open_socket must clear capability cache on entry so a " \
               "reconnect after a half-dead connection can't reuse stale answers"
  end
end
