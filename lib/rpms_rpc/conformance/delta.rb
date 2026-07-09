# frozen_string_literal: true

require "set"
require_relative "fingerprint"
require_relative "package_version"

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

      # PACKAGE #9.4 face of the prescription: packages whose required
      # version the target does not meet — absent, or present at a LOWER
      # version (PackageVersion semantics). `required` may be a Fingerprint
      # (its package_versions are used) or an explicit { name => version }
      # hash. Returns a name-sorted hash:
      #
      #   { "PHARMACY" => { required: "7.0", actual: "6.0" } }
      #
      # `actual` is nil when the package is absent from the target, "" when
      # installed with no recorded version.
      def self.package_gaps(target:, required:)
        required_versions = required.respond_to?(:package_versions) ? required.package_versions : required
        target_versions = target.package_versions

        required_versions.sort.filter_map do |name, required_version|
          actual = target_versions[name]
          next if target_versions.key?(name) && PackageVersion.satisfies?(actual, required_version)

          [ name, { required: required_version.to_s, actual: actual } ]
        end.to_h
      end
    end
  end
end
