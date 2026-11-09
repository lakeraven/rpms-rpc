# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "yaml"
require "rpms_rpc/conformance/build_surface"
require "rpms_rpc/conformance/ingest"

module RpmsRpc
  module Conformance
    # The RPC signature of an rpms-ops build, consumed as a PINNED DEPENDENCY (rpms-rpc#160, #222, #406).
    #
    # rpms-ops attaches to every gated release tag the RPC surface that build serves, captured from the
    # gate's own container and bound to the artifact digest (rpms-ops bin/release_inventory.sh,
    # bin/release_rpcs_json.rb), plus the build record naming the commit it was cut from. This pin
    # takes the one document of that surface and the faces it does not carry:
    #
    #   <tag>-rpcs.json                  the RPC surface: one record per registered RPC (entry point,
    #                                    #8994 codes, parameters, package, reach), and the sha256 of
    #                                    each raw file it was projected from (rpms-ops#732)
    #   <tag>-packages_9_4.txt           PREFIX^NAME^VERSION per installed package (the fingerprint's
    #                                    packages face: rpcs.json names only packages that own an RPC)
    #   <tag>-contexts_19_05.txt         one row per #19.05 entry, tab-separated under its header:
    #                                    OPTION TYPE LOCK RPC RPC_KEY RPC_RULES (rpms-ops#626, #416)
    #   <tag>-INVENTORY-PROVENANCE.json  engine, artifact binding, per-dump sha256 + counts, tool sha,
    #                                    the reach face's sha256 + class counts, the image digest
    #   <tag>-INVENTORY.sha256           sidecar over the raw inventory files (shasum -c shape)
    #   <tag>-PROVENANCE.json            the build record: release, rpms_ops_commit (not in the sidecar)
    #
    # The sidecar does not cover rpcs.json, so rpcs.json is bound to it through its own `inputs`: each
    # raw file it names must be the sidecar's bytes, so the document is the projection of the gated
    # inventory. At pin time every byte is also checked against the release's asset digest.
    #
    # This class is the Gemfile.lock side of that contract:
    #
    #   data/fingerprints/rpms-ops.lock.yml    what is pinned: tag, RPMS version, engine, build
    #                                          commit, artifact sha, per-asset sha256, counts
    #   data/inventories/<tag>/                the assets, byte for byte (the signature)
    #   data/fingerprints/references/<tag>.yml what was derived from exactly those bytes (Ingest)
    #
    # `rake conformance:pin RELEASE=<tag>` downloads, verifies, ingests and writes the lock;
    # `check` proves OFFLINE that the committed signature and fingerprint still match the lock.
    # The committed files are READ through BuildSurface, the one reader of them (#394, #395, #406).
    class InventoryLock
      DEFAULT_PATH = "rpms-ops.lock.yml"
      DEFAULT_REPO = "lakeraven/rpms-ops"
      # The surface document, the packages and contexts faces, and the provenance. A release published
      # before rpms-ops#732 has no rpcs.json, and one before rpms-ops#626 no contexts face: neither can be
      # pinned until re-gated.
      ASSET_SUFFIXES = %w[rpcs.json packages_9_4.txt contexts_19_05.txt INVENTORY-PROVENANCE.json].freeze
      RPCS_SUFFIX = "rpcs.json"
      # The pinned assets the sidecar covers (all but rpcs.json, which is bound through its inputs).
      SIDECAR_COVERED = (ASSET_SUFFIXES - [ RPCS_SUFFIX ]).freeze
      # The raw files rpcs.json must name in its inputs, each held to the sidecar.
      RPCS_INPUTS = %w[broker_8994.txt rpc_reach.txt rpc_signatures.txt packages_9_4.txt INVENTORY-PROVENANCE.json].freeze
      SIDECAR_SUFFIX = "INVENTORY.sha256"
      BUILD_RECORD_SUFFIX = "PROVENANCE.json"
      ENGINES = %w[iris yottadb].freeze
      # A build tag: bcer-<RPMS version>-<yyyymmdd>-<rpms-ops short commit>-<engine>.
      TAG = /\A(?<rpms_version>bcer-\d+\.\d+)-(?<date>\d{8})-(?<short_commit>[0-9a-f]{7,40})-(?<engine>ydb|iris)\z/
      # ^DD(8994,.06): 1 INACTIVE, 2 LOCAL INACTIVE (ACTIVE REMOTELY) block a local broker call;
      # 0 ACTIVE and 3 REMOTE INACTIVE (ACTIVE LOCALLY) do not.
      LOCALLY_INACTIVE = %w[1 2].freeze

      class Error < RpmsRpc::Error; end

      # A verified inventory directory for one tag.
      Inventory = Struct.new(:tag, :dir, :shas, :provenance, :build_record, keyword_init: true) do
        def asset(suffix) = File.join(dir, "#{tag}-#{suffix}")
        def rpcs_json = asset(RPCS_SUFFIX)
        def packages_dump = asset("packages_9_4.txt")
        def engine = provenance["engine"]
        def rpms_version = InventoryLock.parse_tag(tag)[:rpms_version]
        def build_commit = build_record["rpms_ops_commit"]
        def image_ref = provenance.dig("image", "ref")

        # The build's RPC surface, read from these verified files.
        def surface = @surface ||= BuildSurface.load(dir, tag)
        # The sha256 rpcs.json records for a raw file it was projected from (e.g. "broker_8994.txt").
        def input_sha(file) = surface.meta.dig("inputs", file)

        # The facts Ingest stamps into the fingerprint's source.inventory face.
        def to_source
          {
            "tag" => tag,
            "rpms_version" => rpms_version,
            "engine" => engine,
            "build_commit" => build_commit,
            "artifact_sha256" => provenance["artifact_sha256"],
            "rpcs_json_sha256" => shas["#{tag}-#{RPCS_SUFFIX}"],
            "rpcs_json_schema" => surface.meta["schema"],
            # The raw files the document was projected from, as it names them.
            "broker_8994_sha256" => input_sha("broker_8994.txt"),
            "packages_9_4_sha256" => shas["#{tag}-packages_9_4.txt"],
            "rpc_reach_sha256" => input_sha("rpc_reach.txt"),
            "rpc_signatures_sha256" => input_sha("rpc_signatures.txt"),
            "contexts_19_05_sha256" => shas["#{tag}-contexts_19_05.txt"],
            "provenance_sha256" => shas["#{tag}-INVENTORY-PROVENANCE.json"],
            "inventory_tool_commit" => provenance["tool_git_sha"],
            "image" => image_ref
          }.compact
        end
      end

      # { rpms_version:, date:, short_commit:, engine: } for a build tag, nil for anything else
      # (e.g. "bcer-9.0-iris" names a line, not a build).
      def self.parse_tag(tag)
        m = TAG.match(tag.to_s) or return nil
        { rpms_version: m[:rpms_version], date: m[:date], short_commit: m[:short_commit],
          engine: m[:engine] == "ydb" ? "yottadb" : "iris" }
      end

      # Why an RPC is not available on a build, from its #8994 entry (a BuildSurface::Rpc, or a
      # fingerprint entry hash); nil when it is.
      # Available = registered, with an entry point (TAG and ROUTINE), not inactive locally.
      # Whether that entry point exists and a context serves it is the callable gate's question.
      def self.unavailable_reason(meta)
        return "not registered" if meta.nil?

        tag, routine, inactive = meta.is_a?(Hash) ? meta.values_at("tag", "routine", "inactive") : [ meta.tag, meta.routine, meta.inactive ]
        return "registered without an entry point" if tag.to_s.empty? || routine.to_s.empty?
        return "INACTIVE=#{inactive} in #8994" if LOCALLY_INACTIVE.include?(inactive.to_s)

        nil
      end

      # The TAG^ROUTINE a wire fixture's cite leads with ("FASTVIT^ORQQVI (ORQQVI.m:61-84): ...").
      def self.cited_entry_point(cite)
        cite.to_s[/\A\s*([A-Z%][A-Z0-9]{0,7}\^[A-Z%][A-Z0-9]{0,7})\b/, 1]
      end

      def self.sha256(path) = Digest::SHA256.file(path).hexdigest

      # Verify a downloaded/committed inventory directory for TAG: the tag names a build, every
      # asset is present and non-empty, the sidecar agrees with the bytes, the provenance is
      # artifact-bound to THIS tag on the engine the tag names, the build record is for this release
      # at the commit the tag names, and rpcs.json is that build's document: its header names this
      # build, its inputs are the sidecar's bytes, and it lists as many RPCs, in the reach classes,
      # as the provenance counts.
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
        covered = (SIDECAR_COVERED | RPCS_INPUTS).map { |s| "#{tag}-#{s}" }
        missing = covered - expected.keys
        raise Error, "sidecar does not name #{missing.join(', ')}" unless missing.empty?

        shas = names.to_h { |n| [ n, sha256(File.join(dir, n)) ] }
        SIDECAR_COVERED.map { |s| "#{tag}-#{s}" }.each do |n|
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
        problems.concat(face_problems(provenance))
        problems << "build record release #{build_record['release'].inspect} != #{tag.inspect}" unless build_record["release"] == tag
        commit = build_record["rpms_ops_commit"].to_s
        unless commit.match?(/\A[0-9a-f]{40}\z/) && commit.start_with?(parts[:short_commit])
          problems << "build record commit #{commit.inspect} is not the #{parts[:short_commit]} the tag names"
        end
        raise Error, "#{tag}: " + problems.join("; ") unless problems.empty?

        begin
          surface = BuildSurface.load(dir, tag)
        rescue BuildSurface::Error => e
          raise Error, "#{tag}: #{e.message}"
        end
        problems = rpcs_problems(tag, surface, provenance, build_record, expected, records)
        raise Error, "#{tag}: " + problems.join("; ") unless problems.empty?

        Inventory.new(tag: tag, dir: dir, shas: shas, provenance: provenance, build_record: build_record)
      end

      # The reach and signature faces the provenance describes, and the image a -ydb release pins
      # (rpms-ops#727), whose digest is the artifact's.
      def self.face_problems(provenance)
        problems = %w[rpc_reach rpc_signatures].filter_map do |key|
          "provenance has no #{key} face (published before rpms-ops#713? re-gate the release)" unless provenance[key].is_a?(Hash)
        end
        image = provenance["image"]
        if image.is_a?(Hash) && image["digest"] != provenance["artifact_sha256"]
          problems << "provenance image.digest #{image['digest']} is not artifact_sha256 #{provenance['artifact_sha256']}"
        end
        problems
      end

      # rpcs.json against the build it claims to describe: its header names the tag, engine, RPMS version
      # and commit of this build; each raw file in its inputs is the sidecar's bytes (SIDECAR maps file
      # name => sha256); and it lists the RPCs, in the reach classes, the provenance counted.
      def self.rpcs_problems(tag, surface, provenance, build_record, sidecar, records)
        meta = surface.meta
        file = "#{tag}-#{RPCS_SUFFIX}"
        problems = []
        problems << "#{file} engine #{meta['engine'].inspect} is not the provenance's #{provenance['engine'].inspect}" unless meta["engine"] == provenance["engine"]
        problems << "#{file} rpms_version #{meta['rpms_version'].inspect} is not #{parse_tag(tag)[:rpms_version]}" unless meta["rpms_version"] == parse_tag(tag)[:rpms_version]
        commit = meta["commit"].to_s
        unless commit.match?(/\A[0-9a-f]{7,40}\z/) && build_record["rpms_ops_commit"].to_s.start_with?(commit)
          problems << "#{file} commit #{commit.inspect} is not the build record's #{build_record['rpms_ops_commit']}"
        end
        inputs = meta["inputs"].is_a?(Hash) ? meta["inputs"] : {}
        RPCS_INPUTS.each do |input|
          want = sidecar["#{tag}-#{input}"]
          have = inputs[input]
          problems << "#{file} was projected from #{input} #{have.inspect}, not the sidecar's #{want}" unless have == want
        end
        problems << "#{file} lists #{surface.rpcs.size} RPCs, the provenance counted #{records} (truncated?)" unless surface.rpcs.size == records
        { "rpc_reach" => "records", "rpc_signatures" => "rpcs" }.each do |key, count|
          n = provenance.dig(key, count)
          problems << "provenance #{key} counts #{n.inspect} RPCs, #{file} lists #{surface.rpcs.size}" unless n.to_i == surface.rpcs.size
        end
        classes = provenance.dig("rpc_reach", "classes").to_h.sort.to_h
        problems << "#{file} reach classes #{surface.reach_counts} != provenance #{classes}" unless surface.reach_counts == classes
        problems
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
          "image" => inventory.image_ref,
          "reach_classes" => prov.dig("rpc_reach", "classes").to_h.sort.to_h,
          "assets" => inventory.shas.sort.to_h,
          "fingerprint" => fingerprint,
          "rpcs" => rpcs,
          "packages" => packages
        }.compact
        entries[inventory.tag]
      end

      def save
        header = "# rpms-ops builds whose RPC signature rpms-rpc conforms to - written by `rake conformance:pin`; do not hand-edit.\n" \
                 "# Each entry pins the RPC-surface document (rpcs.json), #9.4 and #19.05 faces and build record lakeraven/rpms-ops attaches to that release\n" \
                 "# (sha256 per asset; the bytes are committed under data/inventories/<tag>/), and names the fingerprint\n" \
                 "# ingested from exactly those bytes. test/rpms_rpc/pinned_build_signature_test.rb checks all three agree.\n"
        sorted = { "repo" => repo, "releases" => entries.sort.to_h }
        File.write(path, header + YAML.dump(sorted))
        path
      end

      # { tag => BuildSurface } for every pinned build, read from its committed files.
      def surfaces(inventories_dir:)
        entries.keys.to_h { |tag| [ tag, BuildSurface.load(File.join(inventories_dir, tag), tag) ] }
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
              derived = Ingest.registry(local.surface).sort.to_h
              committed = (YAML.safe_load_file(fp_path, permitted_classes: [ Date ]) || {})["rpcs"] || {}
              drift = (derived.keys | committed.keys).reject { |name| derived[name] == committed[name] }
              problems << "#{tag}: fingerprint rpcs differ from the pinned rpcs.json (#{drift.first(3).join(', ')}#{', ...' if drift.size > 3})" unless drift.empty?
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
        { "rpcs.json" => "rpcs_json_sha256", "packages_9_4.txt" => "packages_9_4_sha256" }.each do |suffix, key|
          want = entry.dig("assets", "#{tag}-#{suffix}")
          have = inv[key]
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
