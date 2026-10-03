# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "yaml"
require "rpms_rpc/conformance/ingest"

module RpmsRpc
  module Conformance
    # The RPC signature of an rpms-ops build, consumed as a PINNED DEPENDENCY (rpms-rpc#160, #222).
    #
    # rpms-ops attaches to every gated release tag the #8994 + #9.4 inventory that build serves,
    # captured from the gate's own container and bound to the artifact digest
    # (rpms-ops bin/release_inventory.sh), plus the build record naming the commit it was cut from:
    #
    #   <tag>-broker_8994.txt            one #8994 0-node per registered RPC:
    #                                    NAME^TAG^ROUTINE^RETURN VALUE TYPE^AVAILABILITY^INACTIVE^...
    #   <tag>-packages_9_4.txt           PREFIX^NAME^VERSION per installed package
    #   <tag>-INVENTORY-PROVENANCE.json  engine, artifact binding, per-dump sha256 + counts, tool sha
    #   <tag>-INVENTORY.sha256           sidecar over the three above (shasum -c shape)
    #   <tag>-PROVENANCE.json            the build record: release, rpms_ops_commit (not in the sidecar)
    #
    # This class is the Gemfile.lock side of that contract:
    #
    #   data/fingerprints/rpms-ops.lock.yml    what is pinned: tag, RPMS version, engine, build
    #                                          commit, artifact sha, per-asset sha256, counts
    #   data/inventories/<tag>/                the five assets, byte for byte (the signature)
    #   data/fingerprints/references/<tag>.yml what was derived from exactly those bytes (Ingest)
    #
    # `rake conformance:pin RELEASE=<tag>` downloads, verifies, ingests and writes the lock;
    # `check` proves OFFLINE that the committed signature and fingerprint still match the lock.
    class InventoryLock
      DEFAULT_PATH = "rpms-ops.lock.yml"
      DEFAULT_REPO = "lakeraven/rpms-ops"
      ASSET_SUFFIXES = %w[broker_8994.txt packages_9_4.txt INVENTORY-PROVENANCE.json].freeze
      SIDECAR_SUFFIX = "INVENTORY.sha256"
      BUILD_RECORD_SUFFIX = "PROVENANCE.json"
      ENGINES = %w[iris yottadb].freeze
      # A build tag: bcer-<RPMS version>-<yyyymmdd>-<rpms-ops short commit>-<engine>.
      TAG = /\A(?<rpms_version>bcer-\d+\.\d+)-(?<date>\d{8})-(?<short_commit>[0-9a-f]{7,40})-(?<engine>ydb|iris)\z/
      # ^DD(8994,.06): 1 INACTIVE, 2 LOCAL INACTIVE (ACTIVE REMOTELY) block a local broker call;
      # 0 ACTIVE and 3 REMOTE INACTIVE (ACTIVE LOCALLY) do not.
      LOCALLY_INACTIVE = %w[1 2].freeze

      class Error < StandardError; end

      # A verified inventory directory for one tag.
      Inventory = Struct.new(:tag, :dir, :shas, :provenance, :build_record, keyword_init: true) do
        def asset(suffix) = File.join(dir, "#{tag}-#{suffix}")
        def broker_dump = asset("broker_8994.txt")
        def packages_dump = asset("packages_9_4.txt")
        def engine = provenance["engine"]
        def rpms_version = InventoryLock.parse_tag(tag)[:rpms_version]
        def build_commit = build_record["rpms_ops_commit"]

        # The facts Ingest stamps into the fingerprint's source.inventory face.
        def to_source
          {
            "tag" => tag,
            "rpms_version" => rpms_version,
            "engine" => engine,
            "build_commit" => build_commit,
            "artifact_sha256" => provenance["artifact_sha256"],
            "broker_8994_sha256" => shas["#{tag}-broker_8994.txt"],
            "packages_9_4_sha256" => shas["#{tag}-packages_9_4.txt"],
            "provenance_sha256" => shas["#{tag}-INVENTORY-PROVENANCE.json"],
            "inventory_tool_commit" => provenance["tool_git_sha"]
          }
        end
      end

      # { rpms_version:, date:, short_commit:, engine: } for a build tag, nil for anything else
      # (e.g. "bcer-9.0-iris" names a line, not a build).
      def self.parse_tag(tag)
        m = TAG.match(tag.to_s) or return nil
        { rpms_version: m[:rpms_version], date: m[:date], short_commit: m[:short_commit],
          engine: m[:engine] == "ydb" ? "yottadb" : "iris" }
      end

      # Why an RPC is not available on a build, from its fingerprint entry; nil when it is.
      # Available = registered, with an entry point (TAG and ROUTINE), not inactive locally.
      def self.unavailable_reason(meta)
        return "not registered" if meta.nil?
        return "registered without an entry point" if meta["tag"].to_s.empty? || meta["routine"].to_s.empty?
        return "INACTIVE=#{meta['inactive']} in #8994" if LOCALLY_INACTIVE.include?(meta["inactive"].to_s)

        nil
      end

      # The TAG^ROUTINE a wire fixture's cite leads with ("FASTVIT^ORQQVI (ORQQVI.m:61-84): ...").
      def self.cited_entry_point(cite)
        cite.to_s[/\A\s*([A-Z%][A-Z0-9]{0,7}\^[A-Z%][A-Z0-9]{0,7})\b/, 1]
      end

      def self.sha256(path) = Digest::SHA256.file(path).hexdigest

      # Verify a downloaded/committed inventory directory for TAG: the tag names a build, every
      # asset is present and non-empty, the sidecar agrees with the bytes, the provenance is
      # artifact-bound to THIS tag on the engine the tag names, the registry is as long as the
      # provenance says, and the build record is for this release at the commit the tag names.
      # Raises Error with the precise reason; returns an Inventory on success.
      def self.verify_dir(tag, dir)
        parts = parse_tag(tag) or raise Error, "#{tag} names no build (want bcer-<version>-<yyyymmdd>-<commit>-<ydb|iris>)"
        raise Error, "inventory dir not found: #{dir}" unless File.directory?(dir)

        names = (ASSET_SUFFIXES + [ BUILD_RECORD_SUFFIX ]).map { |s| "#{tag}-#{s}" }
        names.each do |n|
          path = File.join(dir, n)
          raise Error, "missing or empty asset #{n} in #{dir}" unless File.file?(path) && File.size(path).positive?
        end

        sidecar = File.join(dir, "#{tag}-#{SIDECAR_SUFFIX}")
        raise Error, "missing sidecar #{File.basename(sidecar)}" unless File.file?(sidecar)

        expected = File.readlines(sidecar, chomp: true).each_with_object({}) do |line, h|
          sha, name = line.split(/\s+\*?/, 2)
          h[name.to_s.strip] = sha if sha && name
        end
        covered = ASSET_SUFFIXES.map { |s| "#{tag}-#{s}" }
        missing = covered - expected.keys
        raise Error, "sidecar does not name #{missing.join(', ')}" unless missing.empty?

        shas = names.to_h { |n| [ n, sha256(File.join(dir, n)) ] }
        covered.each do |n|
          raise Error, "sha256 mismatch for #{n}: sidecar #{expected[n]}, file #{shas[n]}" unless expected[n] == shas[n]
        end

        provenance = JSON.parse(File.read(File.join(dir, "#{tag}-INVENTORY-PROVENANCE.json")))
        build_record = JSON.parse(File.read(File.join(dir, "#{tag}-#{BUILD_RECORD_SUFFIX}")))
        problems = []
        problems << "provenance is not artifact_bound" unless provenance["artifact_bound"] == true
        problems << "provenance release_tag #{provenance['release_tag'].inspect} != #{tag.inspect}" unless provenance["release_tag"] == tag
        problems << "provenance engine #{provenance['engine'].inspect} not in #{ENGINES.join('|')}" unless ENGINES.include?(provenance["engine"])
        problems << "provenance engine #{provenance['engine'].inspect} is not the #{parts[:engine]} the tag names" if ENGINES.include?(provenance["engine"]) && provenance["engine"] != parts[:engine]
        problems << "provenance artifact_sha256 is empty" if provenance["artifact_sha256"].to_s.empty?
        records = provenance.dig("dumps", "rpcs", "records").to_i
        problems << "provenance records no rpcs dump" unless records.positive?
        lines = File.foreach(File.join(dir, "#{tag}-broker_8994.txt")).count { |l| !l.strip.empty? }
        problems << "registry has #{lines} lines but provenance counted #{records} rpcs records (truncated?)" if records.positive? && lines != records
        problems << "build record release #{build_record['release'].inspect} != #{tag.inspect}" unless build_record["release"] == tag
        commit = build_record["rpms_ops_commit"].to_s
        unless commit.match?(/\A[0-9a-f]{40}\z/) && commit.start_with?(parts[:short_commit])
          problems << "build record commit #{commit.inspect} is not the #{parts[:short_commit]} the tag names"
        end
        raise Error, "#{tag}: " + problems.join("; ") unless problems.empty?

        Inventory.new(tag: tag, dir: dir, shas: shas, provenance: provenance, build_record: build_record)
      end

      def self.load(path)
        new(path)
      end

      attr_reader :path, :data

      def initialize(path)
        @path = path
        @data = File.file?(path) ? (YAML.safe_load_file(path, permitted_classes: [ Date ]) || {}) : {}
        @data["repo"] ||= DEFAULT_REPO
        @data["releases"] ||= {}
      end

      def repo = data["repo"]
      def entries = data["releases"]
      def [](tag) = entries[tag]

      # Record (or replace) the pin for a verified inventory. FINGERPRINT is the env name the
      # ingested fingerprint was written under (e.g. "references/<tag>").
      def pin!(inventory, fingerprint:, rpcs:, packages:)
        prov = inventory.provenance
        entries[inventory.tag] = {
          "rpms_version" => inventory.rpms_version,
          "engine" => inventory.engine,
          "build_commit" => inventory.build_commit,
          "artifact_sha256" => prov["artifact_sha256"],
          "captured_at" => prov["captured_at"],
          "inventory_tool_commit" => prov["tool_git_sha"],
          "provenance_schema" => prov["schema_version"],
          "assets" => inventory.shas.sort.to_h,
          "fingerprint" => fingerprint,
          "rpcs" => rpcs,
          "packages" => packages
        }
        entries[inventory.tag]
      end

      def save
        header = "# rpms-ops builds whose RPC signature rpms-rpc conforms to - written by `rake conformance:pin`; do not hand-edit.\n" \
                 "# Each entry pins the #8994 + #9.4 inventory and build record lakeraven/rpms-ops attaches to that release\n" \
                 "# (sha256 per asset; the bytes are committed under data/inventories/<tag>/), and names the fingerprint\n" \
                 "# ingested from exactly those bytes. test/rpms_rpc/pinned_build_signature_test.rb checks all three agree.\n"
        sorted = { "repo" => repo, "releases" => entries.sort.to_h }
        File.write(path, header + YAML.dump(sorted))
        path
      end

      # { tag => { rpc name => fingerprint entry } } for every pinned build.
      def pinned_rpcs(fingerprints_dir:)
        entries.to_h do |tag, entry|
          fp = YAML.safe_load_file(File.join(fingerprints_dir, "#{entry['fingerprint']}.yml"), permitted_classes: [ Date ]) || {}
          [ tag, fp["rpcs"] || {} ]
        end
      end

      # Offline consistency: every pinned tag has its fingerprint, and the fingerprint's
      # source.inventory face carries the pinned sha256s + count. If the inventory assets are
      # present locally (INVENTORIES_DIR/<tag>/), they must verify and their bytes must match the
      # lock; with require_inventories they must be present.
      # Returns a list of problem strings (empty = OK).
      def check(fingerprints_dir:, inventories_dir: nil, require_inventories: false)
        problems = []
        entries.each do |tag, entry|
          fp_path = File.join(fingerprints_dir, "#{entry['fingerprint']}.yml")
          if File.file?(fp_path)
            problems.concat(fingerprint_problems(tag, entry, fp_path))
          else
            problems << "#{tag}: pinned fingerprint #{entry['fingerprint']}.yml is missing"
          end

          dir = inventories_dir && File.join(inventories_dir, tag)
          unless dir && File.directory?(dir)
            problems << "#{tag}: the pinned signature is not committed under #{dir || 'data/inventories'}" if require_inventories
            next
          end

          begin
            local = self.class.verify_dir(tag, dir)
            (local.shas.keys | entry["assets"].to_h.keys).each do |name|
              have = local.shas[name]
              want = entry.dig("assets", name)
              problems << "#{tag}: local asset #{name} sha256 #{have} != lock #{want}" if have != want
            end
            problems << "#{tag}: build_commit #{entry['build_commit']} != build record #{local.build_commit}" if entry["build_commit"] != local.build_commit
            if File.file?(fp_path)
              derived = Ingest.parse_dump(local.broker_dump).first.sort.to_h
              committed = (YAML.safe_load_file(fp_path, permitted_classes: [ Date ]) || {})["rpcs"] || {}
              drift = (derived.keys | committed.keys).reject { |name| derived[name] == committed[name] }
              problems << "#{tag}: fingerprint rpcs differ from the pinned dump (#{drift.first(3).join(', ')}#{', ...' if drift.size > 3})" unless drift.empty?
            end
          rescue Error => e
            problems << "#{tag}: local inventory dir fails verification: #{e.message}"
          end
        end
        problems
      end

      private

      def fingerprint_problems(tag, entry, fp_path)
        problems = []
        fp = YAML.safe_load_file(fp_path, permitted_classes: [ Date ]) || {}
        inv = fp.dig("source", "inventory") || {}
        problems << "#{tag}: fingerprint has no source.inventory face (ingested from an unpinned dump?)" if inv.empty?
        problems << "#{tag}: fingerprint source.inventory.tag is #{inv['tag'].inspect}" if !inv.empty? && inv["tag"] != tag
        %w[broker_8994.txt packages_9_4.txt].each do |suffix|
          want = entry.dig("assets", "#{tag}-#{suffix}")
          have = inv["#{suffix.sub('.txt', '')}_sha256"]
          problems << "#{tag}: #{suffix} sha256 lock=#{want} fingerprint=#{have}" if want != have
        end
        problems << "#{tag}: fingerprint build_commit #{inv['build_commit']} != lock #{entry['build_commit']}" if !inv.empty? && inv["build_commit"] != entry["build_commit"]
        n = (fp["rpcs"] || {}).size
        problems << "#{tag}: fingerprint has #{n} RPCs, lock says #{entry['rpcs']}" if entry["rpcs"] && n != entry["rpcs"]
        problems << "#{tag}: fingerprint release #{fp['release'].inspect} != tag" if fp["release"] != tag
        problems
      end
    end
  end
end
