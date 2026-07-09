# frozen_string_literal: true

require "set"
require_relative "fingerprint"

module RpmsRpc
  module Conformance
    # Prescription math (docs/conformance/SPEC.md, "Delta"):
    #
    #   missing = required.rpcs − target.rpcs  (must be provisioned)
    #   extra   = target.rpcs − required.rpcs  (informational)
    #
    # Conformance = requirements ⊆ provisions, i.e. missing is empty.
    # Follow-up: map missing RPCs → KIDS patches / tribe migrations so the
    # delta is actionable, not descriptive.
    module Delta
      # `required` may be a Fingerprint (its rpc_names are used) or an
      # explicit Set/Array of RPC names. Returns sorted name lists:
      # { missing: [...], extra: [...] }.
      def self.between(target:, required:)
        required_names = required.respond_to?(:rpc_names) ? required.rpc_names : Set.new(required)
        target_names = target.rpc_names

        {
          missing: (required_names - target_names).sort,
          extra: (target_names - required_names).sort
        }
      end
    end
  end
end
