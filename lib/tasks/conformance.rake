# frozen_string_literal: true

# Conformance-probe pipeline (docs/conformance/SPEC.md, docs/conformance/CAPTURE.md).
#
#   rake conformance:ingest DUMP=<file-8994 export> ENV=<name> [BACKEND=] [SUBSET=] [PACKAGES=]
#   rake conformance:probe  TARGET=<fingerprint.yml> [REQUIRED=<reference.yml>]
#
# `ingest` turns a dump you captured yourself into a fingerprint; `probe` is CI-side (committed files
# only). The RPC surface of a published openrpms release is fetched at test time, not pinned here:
# `rake openrpms:fetch` (lib/tasks/openrpms.rake, rpms-rpc#724).

namespace :conformance do
  # Fingerprint corpus location. Overridable via FINGERPRINTS_DIR= so the
  # tasks can serve other checkouts/gems (vista-rpc extraction seam);
  # defaults to this repo's data/fingerprints for existing callers.
  FINGERPRINTS_DIR = ENV["FINGERPRINTS_DIR"] ? File.expand_path(ENV["FINGERPRINTS_DIR"]) : File.expand_path("../../data/fingerprints", __dir__)

  desc "Ingest a file-8994 broker dump into data/fingerprints/<ENV>.yml " \
       "(DUMP=, ENV=, BACKEND=iris_rpms, optional SUBSET= allowlist, CAPTURED_AT=, NOTE=, " \
       "PACKAGES=<packages_9_4.txt> for the #9.4 versions face; " \
       "RELEASE= + DAT_SHA= stamp a per-rung reference for references/)."
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
