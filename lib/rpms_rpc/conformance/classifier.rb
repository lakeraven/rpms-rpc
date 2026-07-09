# frozen_string_literal: true

require_relative "fingerprint"
require_relative "package_version"

module RpmsRpc
  module Conformance
    # Scores a target Fingerprint against reference fingerprints (one per
    # release rung) and reports the best match plus neighbors
    # (docs/conformance/SPEC.md, "Classification"):
    #
    #   coverage(ref) = |ref.rpcs ∩ target.rpcs| / |ref.rpcs|
    #
    # Best match = highest coverage; ties broken by smallest symmetric
    # difference of RPC-name sets. An empty reference RPC set scores 0.0
    # (nothing to cover — no divide-by-zero).
    #
    # Each entry also carries an ADDITIVE package signal (PACKAGE #9.4 face):
    #
    #   package_coverage(ref) = fraction of ref's packages whose required
    #                           version the target meets (PackageVersion)
    #
    # package_coverage never influences ranking or classified_as — RPC
    # coverage stays the classification signal. When a reference declares no
    # packages it is nil ("no package data"), deliberately distinct from 1.0
    # ("every declared requirement met") — and no divide-by-zero.
    class Classifier
      def initialize(references:)
        @references = references
      end

      # Returns { classified_as:, coverage:, package_coverage:,
      #           ranked: [{ release:, coverage:, package_coverage: }] }.
      # classified_as is nil when there are no references.
      def classify(target)
        target_names = target.rpc_names
        target_packages = target.package_versions

        ranked = @references.map { |ref| score(ref, target_names, target_packages) }
                            .sort_by { |entry| [ -entry[:coverage], entry[:symmetric_difference] ] }
        best = ranked.first

        {
          classified_as: best && best[:release],
          coverage: best ? best[:coverage] : 0.0,
          package_coverage: best && best[:package_coverage],
          ranked: ranked.map { |entry| entry.slice(:release, :coverage, :package_coverage) }
        }
      end

      private

      def score(ref, target_names, target_packages)
        ref_names = ref.rpc_names
        coverage = ref_names.empty? ? 0.0 : (ref_names & target_names).size.fdiv(ref_names.size)

        {
          release: ref.release,
          coverage: coverage,
          package_coverage: package_coverage(ref.package_versions, target_packages),
          symmetric_difference: (ref_names ^ target_names).size
        }
      end

      def package_coverage(ref_packages, target_packages)
        return nil if ref_packages.empty?

        met = ref_packages.count do |name, required|
          target_packages.key?(name) && PackageVersion.satisfies?(target_packages[name], required)
        end
        met.fdiv(ref_packages.size)
      end
    end
  end
end
