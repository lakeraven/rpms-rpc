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
  # Detection is a per-RPC probe: the Broker reports "RPC doesn't exist" /
  # "<NOLINE>" before the routine runs. The probe sends the formal list the
  # routine declares (`probe:` on `register`), because a routine that reads
  # a formal the frame did not carry dies in M before it answers:
  # PTINFO^BEHOPTCX, GETBDP^BEHOPTPC and CWAD^BEHOCACV all read DFN on
  # their first lines, and a no-parameter probe of each produced
  # "%YDB-E-LVUNDEF Undefined local variable: DFN" on every sign-on while
  # the fetch frames that followed, carrying the DFN, answered (#259).
  # ALL FEATURES REGISTERED HERE MUST RESOLVE TO READ-ONLY RPCS — probing
  # would otherwise have side effects on write paths.
  #
  # Results are cached on the client instance via `Client#supports?`, so
  # each feature is probed at most once per session.
  #
  # Features are added via `register` — stock-VistA features live in
  # server_capabilities/stock_vista.rb, IHS/RPMS-only features in
  # server_capabilities/ihs.rb (bucketed ahead of the vista-rpc
  # extraction). Both register into the one FEATURE_RPCS registry at load
  # time, so requiring this file yields the identical full feature set.
  module ServerCapabilities
    # Feature registry: symbolic feature name => frozen list of RPC names.
    # Mutated only via `register`; treat as read-only everywhere else.
    FEATURE_RPCS = {} # rubocop:disable Style/MutableConstant

    # Parameters a probe sends: RPC name => frozen list. An RPC absent here
    # is probed with no parameters, which is right only when its routine
    # $G's every formal it reads.
    PROBE_PARAMS = {} # rubocop:disable Style/MutableConstant

    # Register the RPC list backing a symbolic feature. The list must
    # resolve to READ-ONLY RPCs only (see module doc) — associated write
    # RPCs gate on the feature but are never probed. `probe:` names the
    # parameters a probe sends per RPC (synthetic values, e.g. DFN "0").
    def self.register(feature, rpcs, probe: {})
      FEATURE_RPCS[feature] = rpcs.dup.freeze
      probe.each { |rpc, params| PROBE_PARAMS[rpc] = params.map(&:to_s).freeze }
    end

    # RPC error messages that indicate the RPC itself is not installed
    # or not registered to the current OPTION. Anything else means the
    # RPC IS present (it ran far enough to raise a different error).
    # The CIA broker words it "Unknown remote procedure: NAME" (#195).
    MISSING_RPC_PATTERN = /<NOLINE>|Remote Procedure .* (?:doesn't exist|not found)|Unknown remote procedure/i

    # Probe whether `client` can call all RPCs backing `feature`.
    # Short-circuits on first missing RPC.
    def self.probe(client, feature)
      rpcs = FEATURE_RPCS[feature]
      raise ArgumentError, "Unknown capability feature: #{feature.inspect}" unless rpcs

      rpcs.all? { |rpc| rpc_present?(client, rpc) }
    end

    def self.rpc_present?(client, rpc_name)
      client.call_rpc(rpc_name, *PROBE_PARAMS.fetch(rpc_name, []))
      true
    rescue RpmsRpc::Client::RpcError => e
      !e.message.match?(MISSING_RPC_PATTERN)
    end
  end
end

require_relative "server_capabilities/stock_vista"
require_relative "server_capabilities/ihs"
