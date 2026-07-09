# frozen_string_literal: true

require "set"
require "yaml"
require "date"

module RpmsRpc
  module Conformance
    # Value object for a declarative instance fingerprint — the read-only
    # facts a Reader captures from a VistA-family instance (or a committed
    # fixture). Schema per docs/conformance/SPEC.md:
    #
    #   backend:    iris_rpms | yottadb_vista | worldvista
    #   lineage:    rpms | vista | worldvista
    #   release:    set on reference fingerprints (e.g. "bcer-8.0"); nil on
    #               probed targets
    #   source:     { "kind" => ..., "captured_at" => ..., "note" => ... }
    #   rpcs:       file #8994 registry — { name => { "tag" =>, "routine" =>,
    #               "return_type" => } }
    #   packages:   file #9.4  — { name => version }   (optional face)
    #   patches:    file #9.7  — [ "APSP*1.0*70", ... ] (optional face)
    #   bmw_tables: BMW.* SQL catalog — IRIS/RPMS only  (optional face)
    class Fingerprint
      attr_reader :backend, :lineage, :release, :source, :rpcs,
                  :packages, :patches, :bmw_tables

      # Build from a plain hash (string keys, as parsed from YAML).
      # Optional faces (source/packages/patches/bmw_tables) default empty;
      # nil per-RPC metadata (hand-authored seed references) normalizes
      # to an empty hash.
      def self.from_h(hash)
        hash = (hash || {}).transform_keys(&:to_s)
        rpcs = (hash["rpcs"] || {}).transform_values { |meta| meta || {} }

        new(
          backend: hash["backend"],
          lineage: hash["lineage"],
          release: hash["release"],
          source: hash["source"] || {},
          rpcs: rpcs,
          packages: hash["packages"] || {},
          patches: hash["patches"] || [],
          bmw_tables: hash["bmw_tables"] || {}
        )
      end

      # Load a committed YAML fingerprint (see data/fingerprints/).
      def self.load(yaml_path)
        from_h(YAML.safe_load_file(yaml_path, permitted_classes: [ Date ]))
      end

      def initialize(backend: nil, lineage: nil, release: nil, source: {},
                     rpcs: {}, packages: {}, patches: [], bmw_tables: {})
        @backend = backend
        @lineage = lineage
        @release = release
        @source = source
        @rpcs = rpcs
        @packages = packages
        @patches = patches
        @bmw_tables = bmw_tables
        freeze
      end

      # The provision set used by Classifier/Delta.
      def rpc_names
        Set.new(rpcs.keys)
      end

      # The #9.4 package-version face, normalized for comparison: string
      # keys and string values (YAML round-trips may yield numeric versions
      # like 7.2; XPDUTL may return none — "" means "installed, version
      # unknown"). Used by Delta.package_gaps and Classifier package_coverage.
      def package_versions
        packages.to_h { |name, version| [ name.to_s, version.to_s ] }
      end

      def to_h
        {
          "backend" => backend,
          "lineage" => lineage,
          "release" => release,
          "source" => source,
          "rpcs" => rpcs,
          "packages" => packages,
          "patches" => patches,
          "bmw_tables" => bmw_tables
        }
      end
    end
  end
end
