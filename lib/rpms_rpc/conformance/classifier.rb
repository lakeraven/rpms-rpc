# frozen_string_literal: true

require_relative "fingerprint"

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
    class Classifier
      def initialize(references:)
        @references = references
      end

      # Returns { classified_as:, coverage:, ranked: [{ release:, coverage: }] }.
      # classified_as is nil when there are no references.
      def classify(target)
        target_names = target.rpc_names

        ranked = @references.map { |ref| score(ref, target_names) }
                            .sort_by { |entry| [-entry[:coverage], entry[:symmetric_difference]] }
        best = ranked.first

        {
          classified_as: best && best[:release],
          coverage: best ? best[:coverage] : 0.0,
          ranked: ranked.map { |entry| entry.slice(:release, :coverage) }
        }
      end

      private

      def score(ref, target_names)
        ref_names = ref.rpc_names
        coverage = ref_names.empty? ? 0.0 : (ref_names & target_names).size.fdiv(ref_names.size)

        {
          release: ref.release,
          coverage: coverage,
          symmetric_difference: (ref_names ^ target_names).size
        }
      end
    end
  end
end
