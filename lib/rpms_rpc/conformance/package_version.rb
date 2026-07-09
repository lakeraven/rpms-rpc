# frozen_string_literal: true

require "rubygems"

module RpmsRpc
  module Conformance
    # Version-satisfaction test for PACKAGE #9.4 versions, shared by
    # Delta.package_gaps and Classifier package_coverage.
    #
    # Semantics: `actual` satisfies `required` when it is present and at
    # least as new. Real #9.4 versions are mostly Gem::Version-parseable
    # ("7.2", "99.1", "2"), so those compare numerically ("2" == "2.0",
    # "8.1" > "8.0"); unparseable outliers (".5" — PATIENT MERGE in the
    # wild) fall back to string equality. Edge cases:
    #
    #   required "" (version-less package) — satisfied by mere presence.
    #   actual nil/"" against a versioned requirement — not satisfied
    #     (can't prove the target meets the floor).
    module PackageVersion
      module_function

      def satisfies?(actual, required)
        required = required.to_s.strip
        return true if required.empty?

        actual = actual.to_s.strip
        return false if actual.empty?

        Gem::Version.new(actual) >= Gem::Version.new(required)
      rescue ArgumentError
        actual == required
      end
    end
  end
end
