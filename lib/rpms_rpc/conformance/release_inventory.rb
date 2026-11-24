# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "json"
require "open3"
require "time"
require "rpms_rpc/conformance/build_surface"

module RpmsRpc
  module Conformance
    # The RPC signature of an openrpms release, fetched at test time from the release itself
    # (rpms-rpc#724 step 1; before it, one release was pinned in a lock file and committed here).
    #
    # openrpms attaches to every gated release tag the RPC surface that build serves, captured from the
    # gate's own container and bound to the artifact digest (openrpms bin/release_inventory.sh,
    # bin/release_rpcs_json.rb), plus the build record naming the commit it was cut from:
    #
    #   <tag>-rpcs.json                  the RPC surface: one record per registered RPC (entry point,
    #                                    #8994 codes, parameters, package, reach), and the sha256 of
    #                                    each raw file it was projected from (openrpms#732)
    #   <tag>-packages_9_4.txt           PREFIX^NAME^VERSION per installed package
    #   <tag>-contexts_19_05.txt         one row per #19.05 entry, tab-separated under its header:
    #                                    OPTION TYPE LOCK RPC RPC_KEY RPC_RULES (openrpms#626, #416)
    #   <tag>-INVENTORY-PROVENANCE.json  engine, artifact binding, per-dump sha256 + counts, tool sha,
    #                                    the reach face's sha256 + class counts, the image digest
    #   <tag>-INVENTORY.sha256           sidecar over the raw inventory files (shasum -c shape)
    #   <tag>-PROVENANCE.json            the build record: release, rpms_ops_commit (not in the sidecar)
    #
    # The sidecar does not cover rpcs.json, so rpcs.json is bound to it through its own `inputs`: each
    # raw file it names must be the sidecar's bytes. Every downloaded byte is also checked against the
    # digest GitHub records for the release asset.
    #
    # Which release: OPENRPMS_RELEASE=<tag> when set, otherwise the newest published bcer-*-ydb release
    # that carries the inventory (`latest_tag`). `resolve!` downloads it into the cache
    # (OPENRPMS_INVENTORIES, default tmp/openrpms/ in the checkout), verifies it, and records it in
    # <cache>/current.json: the release this checkout tests against, which `current` reads back offline
    # and CI publishes as its "tested against" record. Nothing here is committed.
    class ReleaseInventory
      REPO = "lakeraven/openrpms"
      # Names the release to test against instead of the latest.
      TAG_ENV = "OPENRPMS_RELEASE"
      # The cache root (default: tmp/openrpms/ in the checkout).
      CACHE_ENV = "OPENRPMS_INVENTORIES"
      DEFAULT_CACHE = File.expand_path("../../../tmp/openrpms", __dir__)
      CURRENT_FILE = "current.json"
      # The engine the gem's tests run against: the YottaDB image anyone with access can run.
      LATEST_ENGINE = "ydb"
      # The surface document, the packages and contexts faces, and the provenance. A release published
      # before openrpms#732 has no rpcs.json, and one before openrpms#626 no contexts face: neither can be
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
      # A build tag: bcer-<RPMS version>-<yyyymmdd>-<openrpms short commit>-<engine>.
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
        def rpms_version = ReleaseInventory.parse_tag(tag)[:rpms_version]
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
      # (openrpms#727), whose digest is the artifact's.
      def self.face_problems(provenance)
        problems = %w[rpc_reach rpc_signatures].filter_map do |key|
          "provenance has no #{key} face (published before openrpms#713? re-gate the release)" unless provenance[key].is_a?(Hash)
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
          # Each face the provenance describes is the raw file rpcs.json was projected from.
          sha = provenance.dig(key, "sha256")
          problems << "provenance #{key}.sha256 #{sha.inspect} is not #{file}'s #{key}.txt input #{inputs["#{key}.txt"]}" unless sha == inputs["#{key}.txt"]
        end
        classes = provenance.dig("rpc_reach", "classes").to_h.sort.to_h
        problems << "#{file} reach classes #{surface.reach_counts} != provenance #{classes}" unless surface.reach_counts == classes
        problems
      end

      # --- which release, fetched and verified ------------------------------------------------------

      # The cache root: OPENRPMS_INVENTORIES when set and not blank, else tmp/openrpms/ in the checkout.
      def self.cache_root(env = ENV)
        chosen = env[CACHE_ENV].to_s.strip
        chosen.empty? ? DEFAULT_CACHE : File.expand_path(chosen)
      end

      # Every asset a release must carry for the gem to test against it.
      def self.asset_names(tag)
        (ASSET_SUFFIXES + [ SIDECAR_SUFFIX, BUILD_RECORD_SUFFIX ]).map { |s| "#{tag}-#{s}" }
      end

      # The newest published (not draft, not prerelease) bcer-*-<engine> release whose assets include the
      # whole inventory, from a GitHub releases list. A release published without its inventory (a
      # re-tag, a gate that died before attaching it) is passed over, not tested against.
      # { tag:, published_at: }; Error when none qualifies.
      def self.pick_latest(releases, engine: LATEST_ENGINE)
        chosen = Array(releases).select { |r| testable?(r, engine) }.max_by { |r| r["published_at"].to_s }
        raise Error, "no published bcer-*-#{engine} release on #{REPO} carries the inventory (#{ASSET_SUFFIXES.join(', ')})" unless chosen

        { tag: chosen["tag_name"], published_at: chosen["published_at"] }
      end

      def self.testable?(release, engine)
        return false unless release.is_a?(Hash)
        return false if release["draft"] || release["prerelease"]

        parts = parse_tag(release["tag_name"])
        return false unless parts && parts[:engine] == (engine == "ydb" ? "yottadb" : "iris")

        names = Array(release["assets"]).map { |a| a.is_a?(Hash) ? a["name"] : nil }
        (asset_names(release["tag_name"]) - names).empty?
      end

      # The latest testable release tag on REPO, read with `gh api` (GH_TOKEN or `gh auth login`).
      def self.latest_tag(repo: REPO)
        out, err, status = Open3.capture3("gh", "api", "--paginate", "--slurp", "repos/#{repo}/releases")
        raise Error, "cannot list #{repo} releases (gh api: #{err.to_s.lines.first.to_s.strip}); a token that can read #{repo} is needed" unless status.success?

        pick_latest(JSON.parse(out).flatten(1))[:tag]
      rescue JSON::ParserError
        raise Error, "cannot list #{repo} releases: gh api returned no JSON list"
      end

      # Download TAG's inventory into ROOT/<tag>/ (kept when it is already there and verifies), check each
      # byte against the release's asset digest, verify it, and return the Inventory.
      def self.fetch(tag, root: cache_root, repo: REPO)
        parse_tag(tag) or raise Error, "#{tag.inspect} names no build (want bcer-<version>-<yyyymmdd>-<commit>-<ydb|iris>)"
        dir = File.join(root, tag)
        begin
          return verify_dir(tag, dir) if File.directory?(dir)
        rescue Error
          FileUtils.rm_rf(dir) # a partial or stale download: fetch it again
        end

        FileUtils.mkdir_p(dir)
        names = asset_names(tag)
        patterns = names.flat_map { |name| [ "--pattern", name ] }
        _, err, status = Open3.capture3("gh", "release", "download", tag, "--repo", repo, *patterns, "--dir", dir, "--clobber")
        raise Error, "gh release download #{tag} from #{repo} failed: #{err.to_s.lines.first.to_s.strip}" unless status.success?

        out, err, status = Open3.capture3("gh", "release", "view", tag, "--repo", repo, "--json", "assets")
        raise Error, "gh release view #{tag} failed: #{err.to_s.lines.first.to_s.strip}" unless status.success?

        digests = JSON.parse(out)["assets"].to_h { |a| [ a["name"], a["digest"].to_s.delete_prefix("sha256:") ] }
        names.each do |name|
          have = sha256(File.join(dir, name))
          raise Error, "#{name}: sha256 #{have} is not the release asset digest #{digests[name].inspect}" unless digests[name] == have
        end
        verify_dir(tag, dir)
      end

      # Fetch and verify the release to test against (OPENRPMS_RELEASE, or the latest), and record it as
      # this checkout's current release. Returns the Inventory.
      def self.resolve!(env: ENV, root: cache_root(env), repo: REPO)
        override = env[TAG_ENV].to_s.strip
        tag = override.empty? ? latest_tag(repo: repo) : override
        inventory = fetch(tag, root: root, repo: repo)
        record_current!(inventory, root: root, chosen_by: override.empty? ? "latest" : TAG_ENV)
        inventory
      end

      # Write ROOT/current.json: which release this checkout tests against, and how it was chosen.
      def self.record_current!(inventory, root:, chosen_by:)
        doc = {
          "repo" => REPO,
          "tag" => inventory.tag,
          "chosen_by" => chosen_by,
          "image" => inventory.image_ref,
          "build_commit" => inventory.build_commit,
          "rpcs_json_sha256" => inventory.shas["#{inventory.tag}-#{RPCS_SUFFIX}"],
          "rpcs" => inventory.surface.rpcs.size,
          "resolved_at" => Time.now.utc.iso8601
        }.compact
        FileUtils.mkdir_p(root)
        File.write(File.join(root, CURRENT_FILE), "#{JSON.pretty_generate(doc)}\n")
        doc
      end

      # The release `resolve!` last recorded in ROOT, as a verified Inventory, without the network.
      # Error when none was recorded or its files no longer verify.
      def self.current(root: cache_root)
        doc = current_record(root: root)
        verify_dir(doc.fetch("tag"), File.join(root, doc.fetch("tag")))
      end

      # ROOT/current.json, parsed. Error when there is none.
      def self.current_record(root: cache_root)
        path = File.join(root, CURRENT_FILE)
        raise Error, "no openrpms release fetched into #{root}: run `bundle exec rake openrpms:fetch` (OPENRPMS_RELEASE=<tag> for a specific one)" unless File.file?(path)

        doc = JSON.parse(File.read(path))
        raise Error, "#{path} names no release" unless doc.is_a?(Hash) && doc["tag"].is_a?(String)

        doc
      rescue JSON::ParserError => e
        raise Error, "#{path} is not JSON (#{e.message})"
      end
    end
  end
end
