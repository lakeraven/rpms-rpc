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
end
