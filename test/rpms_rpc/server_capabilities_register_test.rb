# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/client"
require "rpms_rpc/server_capabilities"

# Seam test for the ServerCapabilities register API (vista-rpc extraction
# Phase 1): features are added via `register(feature, rpcs)` instead of a
# frozen literal constant, with resolution identical to the old
# FEATURE_RPCS hash. The full pre-refactor feature set is pinned below so
# the constant→registry conversion is provably a zero-behavior change.
class RpmsRpc::ServerCapabilitiesRegisterTest < Minitest::Test
  class ProbingClient
    def initialize(missing: [])
      @missing = missing
    end

    def call_rpc(rpc_name, *_params)
      if @missing.include?(rpc_name)
        raise RpmsRpc::Client::RpcError, "Remote Procedure '#{rpc_name}' doesn't exist"
      end
      ""
    end
  end

  TEMP_FEATURE = :register_api_seam_test_feature

  def teardown
    RpmsRpc::ServerCapabilities::FEATURE_RPCS.delete(TEMP_FEATURE)
    RpmsRpc::ServerCapabilities::PROBE_PARAMS.delete("FAKE READ RPC")
  end

  # `probe:` names what the probe frame carries per RPC; an RPC registered
  # without it is still probed bare (#259).
  def test_register_probe_params_ride_the_probe_frame
    recording = Class.new do
      attr_reader :frames
      def initialize = @frames = []
      def call_rpc(rpc_name, *params)
        @frames << [ rpc_name, params ]
        ""
      end
    end

    RpmsRpc::ServerCapabilities.register(TEMP_FEATURE, [ "FAKE READ RPC" ], probe: { "FAKE READ RPC" => [ 0, "" ] })
    client = recording.new
    RpmsRpc::ServerCapabilities.probe(client, TEMP_FEATURE)
    assert_equal [ [ "FAKE READ RPC", [ "0", "" ] ] ], client.frames

    RpmsRpc::ServerCapabilities::PROBE_PARAMS.delete("FAKE READ RPC")
    RpmsRpc::ServerCapabilities.register(TEMP_FEATURE, [ "FAKE READ RPC" ])
    client = recording.new
    RpmsRpc::ServerCapabilities.probe(client, TEMP_FEATURE)
    assert_equal [ [ "FAKE READ RPC", [] ] ], client.frames
  end

  # -- register API -----------------------------------------------------------

  def test_register_makes_feature_probeable
    RpmsRpc::ServerCapabilities.register(TEMP_FEATURE, [ "FAKE READ RPC" ])

    assert_equal true,
                 RpmsRpc::ServerCapabilities.probe(ProbingClient.new, TEMP_FEATURE)
    assert_equal false,
                 RpmsRpc::ServerCapabilities.probe(ProbingClient.new(missing: [ "FAKE READ RPC" ]), TEMP_FEATURE)
  end

  def test_register_exposes_feature_through_feature_rpcs
    RpmsRpc::ServerCapabilities.register(TEMP_FEATURE, [ "FAKE READ RPC" ])

    assert_equal [ "FAKE READ RPC" ],
                 RpmsRpc::ServerCapabilities::FEATURE_RPCS[TEMP_FEATURE]
  end

  def test_registered_rpc_lists_are_frozen
    RpmsRpc::ServerCapabilities.register(TEMP_FEATURE, [ "FAKE READ RPC" ])

    assert RpmsRpc::ServerCapabilities::FEATURE_RPCS[TEMP_FEATURE].frozen?,
           "register must freeze the RPC list, matching the old frozen-literal behavior"
  end

  # -- feature-set pin ---------------------------------------------------------
  #
  # Exact snapshot of FEATURE_RPCS. If this test fails, a feature was
  # dropped, renamed, or its RPC list changed. Every probe name must also
  # be registered on a pinned registry (registered_rpc_names_test.rb): the
  # ten features once pinned here beside these probed names no built 9.0
  # image registers, and went with their callers (#207).

  PINNED_FEATURES = {
    patient_chart_banner: [ "BEHOPTCX PTINFO", "BEHOPTPC GETBDP", "BEHOCACV CWAD" ],
    bmc_referral_workflow: [ "BMC GET REFERENCE DATA" ],
    orqqpl_problem_workflow: [ "ORQQPL INIT PT" ] # DETAIL until #259: it needs a real problem IEN
  }.freeze

  def test_feature_set_is_identical_to_the_pinned_constant
    actual = RpmsRpc::ServerCapabilities::FEATURE_RPCS.except(TEMP_FEATURE)

    assert_equal PINNED_FEATURES.keys.sort, actual.keys.sort
    PINNED_FEATURES.each do |feature, rpcs|
      assert_equal rpcs, actual[feature], "RPC list changed for #{feature.inspect}"
    end
  end
end
