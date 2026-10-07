# frozen_string_literal: true

# Conformance-probe pipeline (docs/conformance/SPEC.md, docs/conformance/CAPTURE.md).
#
#   rake conformance:pin    RELEASE=<rpms-ops tag> [REPO=] [SOURCE=<dir>] [ENV=]   pinned dependency
#   rake conformance:check                                                       offline pin audit
#   rake conformance:ingest DUMP=<file-8994 export> ENV=<name> [BACKEND=] [SUBSET=] [PACKAGES=]
#   rake conformance:probe  TARGET=<fingerprint.yml> [REQUIRED=<reference.yml>]
#
# `pin` fetches + verifies a published rpms-ops release inventory and ingests it (the
# capture-side step for anything rpms-ops has gated); `ingest` is the raw form of the same
# step for a dump you captured yourself; `check` and `probe` are CI-side (committed files only).

namespace :conformance do
  # Fingerprint corpus location. Overridable via FINGERPRINTS_DIR= so the
  # tasks can serve other checkouts/gems (vista-rpc extraction seam);
  # defaults to this repo's data/fingerprints for existing callers.
  FINGERPRINTS_DIR = ENV["FINGERPRINTS_DIR"] ? File.expand_path(ENV["FINGERPRINTS_DIR"]) : File.expand_path("../../data/fingerprints", __dir__)

  desc "Ingest a file-8994 broker dump into data/fingerprints/<ENV>.yml " \
       "(DUMP=, ENV=, BACKEND=iris_rpms, optional SUBSET= allowlist, CAPTURED_AT=, NOTE=, " \
       "PACKAGES=<packages_9_4.txt> for the #9.4 versions face; " \
       "RELEASE= + DAT_SHA= stamp a per-rung reference for references/). " \
       "Prefer conformance:pin for a published rpms-ops release."
  task :ingest do
    require "rpms_rpc/conformance/ingest"

    dump_path = ENV["DUMP"] or abort "conformance:ingest requires DUMP=<file-8994 export>"
    env_name = ENV["ENV"] or abort "conformance:ingest requires ENV=<fingerprint name>"

    r = RpmsRpc::Conformance::Ingest.run(
      dump: dump_path, env: env_name, fingerprints_dir: FINGERPRINTS_DIR,
      backend: ENV["BACKEND"] || "iris_rpms",
      captured_at: ENV["CAPTURED_AT"] || Date.today.iso8601,
      packages: ENV["PACKAGES"], subset: ENV["SUBSET"],
      release: ENV["RELEASE"], dat_sha: ENV["DAT_SHA"], note: ENV["NOTE"]
    )
    puts "Wrote #{r[:path]} (#{r[:rpcs]} RPCs#{" of #{r[:total]} in dump" if r[:subset_note]}" \
         "#{", #{r[:packages]} packages" unless r[:packages].zero?})"
  end

  # ---- the pinned-dependency contract with rpms-ops (rpms-rpc#160, #222) -----------------------
  # rpms-ops attaches, to every gated release, the #8994 + #9.4 inventory that build serves
  # (<tag>-broker_8994.txt, -packages_9_4.txt, -INVENTORY-PROVENANCE.json, -INVENTORY.sha256;
  # rpms-ops bin/release_inventory.sh + bin/publish_inventory.sh) and the build record
  # (<tag>-PROVENANCE.json, naming the commit). `pin` is the `bundle install` of that contract,
  # `check` its `bundle check`. The five files are committed under data/inventories/<tag>/:
  # they are the signature the gem is held to.
  INVENTORIES_DIR = ENV["INVENTORIES_DIR"] ? File.expand_path(ENV["INVENTORIES_DIR"]) : File.expand_path("../../data/inventories", __dir__)
  LOCK_PATH = File.join(FINGERPRINTS_DIR, "rpms-ops.lock.yml")

  desc "Pin the RPC signature of an rpms-ops build: RELEASE=<tag> [REPO=lakeraven/rpms-ops] " \
       "[SOURCE=<dir holding the five assets; skips the download>] [ENV=references/<tag>]. " \
       "Downloads the inventory + build record (gh release download), checks each against the " \
       "release's asset digest, verifies sidecar, binding and build commit, commits the bytes to " \
       "data/inventories/<tag>/, ingests the fingerprint and records the pin in data/fingerprints/rpms-ops.lock.yml."
  task :pin do
    require "fileutils"
    require "json"
    require "open3"
    require "rpms_rpc/conformance/ingest"
    require "rpms_rpc/conformance/inventory_lock"

    lock_class = RpmsRpc::Conformance::InventoryLock
    tag = ENV["RELEASE"] or abort "conformance:pin requires RELEASE=<rpms-ops release tag, e.g. bcer-9.0-20260930-8c88e47-ydb>"
    abort "refusing RELEASE with unsafe characters: #{tag.inspect}" unless tag.match?(/\A[A-Za-z0-9._-]+\z/)
    abort "#{tag} names no build (want bcer-<version>-<yyyymmdd>-<commit>-<ydb|iris>)" unless lock_class.parse_tag(tag)
    lock = lock_class.load(LOCK_PATH)
    repo = ENV["REPO"] || lock.repo
    dir = File.join(INVENTORIES_DIR, tag)
    assets = (lock_class::ASSET_SUFFIXES + [ lock_class::SIDECAR_SUFFIX, lock_class::BUILD_RECORD_SUFFIX ]).map { |s| "#{tag}-#{s}" }

    FileUtils.mkdir_p(dir)
    if ENV["SOURCE"]
      assets.each { |name| FileUtils.cp(File.join(ENV["SOURCE"], name), dir) }
    else
      puts "Downloading #{assets.size} assets of #{tag} from #{repo} into #{dir}"
      patterns = assets.flat_map { |name| [ "--pattern", name ] }
      ok = system("gh", "release", "download", tag, "--repo", repo, *patterns, "--dir", dir, "--clobber")
      abort "gh release download failed for #{tag} on #{repo} (published? inventory attached via rpms-ops bin/publish_inventory.sh? gh auth?)" unless ok

      # The build record is not in the sidecar: bind every downloaded byte to the digest GitHub
      # records for the release asset.
      out, status = Open3.capture2("gh", "release", "view", tag, "--repo", repo, "--json", "assets")
      abort "gh release view failed for #{tag}" unless status.success?
      digests = JSON.parse(out)["assets"].to_h { |a| [ a["name"], a["digest"].to_s.delete_prefix("sha256:") ] }
      assets.each do |name|
        have = lock_class.sha256(File.join(dir, name))
        abort "#{name}: sha256 #{have} is not the release asset digest #{digests[name].inspect}" unless digests[name] == have
      end
    end

    begin
      inv = lock_class.verify_dir(tag, dir)
    rescue lock_class::Error => e
      abort "inventory for #{tag} REJECTED: #{e.message}"
    end

    env_name = ENV["ENV"] || "references/#{tag}"
    r = RpmsRpc::Conformance::Ingest.run(
      dump: inv.broker_dump, packages: inv.packages_dump, env: env_name, fingerprints_dir: FINGERPRINTS_DIR,
      backend: RpmsRpc::Conformance::Ingest::BACKEND_FOR_ENGINE.fetch(inv.engine),
      captured_at: inv.provenance["captured_at"].to_s[0, 10],
      release: tag, dat_sha: inv.provenance["artifact_sha256"],
      note: "rpms-ops release inventory #{tag} (#{repo}), pinned by conformance:pin",
      inventory: inv.to_source
    )
    lock.pin!(inv, fingerprint: env_name, rpcs: r[:rpcs], packages: r[:packages])
    lock.save
    puts "Pinned #{tag} (#{inv.rpms_version}, engine #{inv.engine}, commit #{inv.build_commit}, " \
         "#{r[:rpcs]} RPCs, #{r[:packages]} packages)"
    puts "  signature:   #{dir}"
    puts "  fingerprint: #{r[:path]}"
    puts "  lock:        #{LOCK_PATH}"
    puts "  commit all three."
  end

  desc "Offline check: every pin in data/fingerprints/rpms-ops.lock.yml has its committed signature " \
       "(data/inventories/<tag>/) and fingerprint, both matching the pinned bytes. " \
       "test/rpms_rpc/pinned_build_signature_test.rb runs the same check in `rake test`."
  task :check do
    require "rpms_rpc/conformance/inventory_lock"

    abort "conformance:check: no #{LOCK_PATH}; nothing pinned (run conformance:pin RELEASE=<tag>)" unless File.file?(LOCK_PATH)
    lock = RpmsRpc::Conformance::InventoryLock.load(LOCK_PATH)
    problems = lock.check(fingerprints_dir: FINGERPRINTS_DIR, inventories_dir: INVENTORIES_DIR, require_inventories: true)
    if problems.empty?
      puts "conformance:check OK: #{lock.entries.size} pinned build(s): #{lock.entries.keys.join(', ')}"
    else
      problems.each { |p| warn "  #{p}" }
      abort "conformance:check FAILED (#{problems.size} problem(s)): re-run conformance:pin for the affected tag; never hand-edit a pinned file"
    end
  end

  desc "Classify TARGET= fingerprint against reference rungs; with REQUIRED=, " \
       "print the delta and fail if any required RPC is missing (CI gate)"
  task :probe do
    require "rpms_rpc/conformance"

    target_path = ENV["TARGET"] or abort "conformance:probe requires TARGET=<fingerprint.yml>"
    target = RpmsRpc::Conformance::FixtureReader.new(target_path).fingerprint

    references_dir = File.join(FINGERPRINTS_DIR, "references")
    references = RpmsRpc::Conformance::FixtureReader.reference_paths(references_dir).map do |path|
      RpmsRpc::Conformance::FixtureReader.new(path).fingerprint
    end
    placeholders = Dir.glob(File.join(references_dir, "*.yml")).sort.select do |path|
      RpmsRpc::Conformance::FixtureReader.placeholder?(path)
    end
    puts "Not ranked (hand-authored placeholders): #{placeholders.map { |p| File.basename(p) }.join(", ")}" unless placeholders.empty?

    puts "Target: #{target_path} (#{target.rpc_names.size} RPCs, backend #{target.backend})"

    result = RpmsRpc::Conformance::Classifier.new(references: references).classify(target)
    puts "Classified as: #{result[:classified_as] || "(no references)"} " \
         "(coverage #{format("%.2f", result[:coverage])})"
    result[:ranked].each do |entry|
      line = "  #{entry[:release]}: coverage #{format("%.2f", entry[:coverage])}"
      line += ", package coverage #{format("%.2f", entry[:package_coverage])}" if entry[:package_coverage]
      puts line
    end

    if ENV["REQUIRED"]
      required = RpmsRpc::Conformance::FixtureReader.new(ENV["REQUIRED"]).fingerprint
      delta = RpmsRpc::Conformance::Delta.between(target: target, required: required)

      puts "Delta vs #{required.release || ENV["REQUIRED"]}: " \
           "#{delta[:missing].size} missing, #{delta[:extra].size} extra"
      delta[:missing].each { |rpc| puts "  missing: #{rpc}" }

      # PACKAGE #9.4 face — informational for now; the conformance gate
      # stays RPC-based until per-rung package references are authoritative.
      package_gaps = RpmsRpc::Conformance::Delta.package_gaps(target: target, required: required)
      unless package_gaps.empty?
        puts "Package gaps vs #{required.release || ENV["REQUIRED"]}: #{package_gaps.size}"
        package_gaps.each do |name, gap|
          puts "  package: #{name} requires #{gap[:required]}, target has #{gap[:actual] || "(absent)"}"
        end
      end

      abort "Target does not conform to #{required.release || ENV["REQUIRED"]}" unless delta[:missing].empty?
    end
  end
end
