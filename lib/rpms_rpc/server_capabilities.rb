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
