# frozen_string_literal: true

# RPC coverage against ONE backend's registry (rpms-rpc#270).
#
#   rake rpc:coverage   offline, CI-safe: pinned registry x committed live evidence -> one number
#   rake rpc:coverage_html  the same report in SimpleCov's HTML interface, one file per package
#   rake rpc:live BACKEND=<label> BROKER_HOST= BROKER_PORT= RPMS_ACCESS= RPMS_VERIFY= [RPMS_CONTEXT=]
#                       runs the read catalogue against a live CIA broker and merges the result
#                       into <evidence dir>/<BACKEND>.json
#
# Live evidence is a build-specific artifact, so it lives in lakeraven/rpms-diffs, not here:
# <evidence dir> is rpc-coverage/live/ in an rpms-diffs checkout, by default the sibling of this
# repo (../rpms-diffs). Override it with RPMS_DIFFS_DIR= (the checkout) or RPC_EVIDENCE_DIR= (the dir).
#
# Config: data/rpc_coverage/config.yml (backend, registry, minimum_percent, max_unregistered).
# The implementation lives in tools/rpc_coverage/, which is not part of the gem.
namespace :rpc do
  rpc_root = File.expand_path("../..", __dir__)
  rpc_tool = File.join(rpc_root, "tools/rpc_coverage/rpc_coverage.rb")
  rpc_config = lambda do
    require "yaml"
    YAML.safe_load_file(File.join(rpc_root, "data/rpc_coverage/config.yml"))
  end
  rpc_evidence_dir = lambda do
    diffs = ENV["RPMS_DIFFS_DIR"] || File.expand_path("../rpms-diffs", rpc_root)
    dir = File.expand_path(ENV["RPC_EVIDENCE_DIR"] || File.join(diffs, "rpc-coverage/live"))
    unless Dir.exist?(dir)
      abort "no live evidence dir at #{dir}: clone lakeraven/rpms-diffs beside this repo, " \
            "or set RPMS_DIFFS_DIR= (the checkout) or RPC_EVIDENCE_DIR= (the dir)"
    end
    dir
  end

  desc "RPC coverage of the pinned backend registry (RPC_REGISTRY=, RPC_BACKEND= override config)"
  task :coverage do
    abort "rpc:coverage needs a source checkout (#{rpc_tool} is not in the gem)" unless File.exist?(rpc_tool)
    require rpc_tool
    require "fileutils"
    require "json"

    cfg = rpc_config.call
    backend = ENV["RPC_BACKEND"] || cfg.fetch("backend")
    registry_path = File.expand_path(ENV["RPC_REGISTRY"] || cfg.fetch("registry"), rpc_root)
    evidence_path = File.join(rpc_evidence_dir.call, "#{backend}.json")
    abort "no live evidence for #{backend} at #{evidence_path} (rake rpc:live BACKEND=#{backend} writes it)" unless File.exist?(evidence_path)

    registry = RpcCoverage.load_registry(registry_path)
    exclusions = RpcCoverage.load_exclusions(File.join(rpc_root, "data/rpc_coverage/exclusions.yml"))
    evidence = RpcCoverage.load_evidence(evidence_path, backend)
    problems = RpcCoverage.registry_problems(registry) +
               RpcCoverage.exclusion_problems(exclusions, registry) +
               RpcCoverage.evidence_problems(evidence, secrets: [ ENV["RPMS_ACCESS"], ENV["RPMS_VERIFY"] ])
    report = RpcCoverage.compute(registry: registry, declared: RpcCoverage.declared_names(rpc_root),
                                 evidence: evidence, exclusions: exclusions, backend: backend)
    problems += RpcCoverage.gate_problems(report, max_unregistered: cfg["max_unregistered"])
    notes = RpcCoverage.coverage_notes(report, minimum_percent: cfg["minimum_percent"])

    out = File.join(rpc_root, "coverage/rpc")
    FileUtils.mkdir_p(out)
    File.write(File.join(out, "rpcs.tsv"), report.tsv)
    File.write(File.join(out, "summary.json"), JSON.pretty_generate(report.to_h.merge(problems: problems, notes: notes)) + "\n")

    puts report.one_liner
    puts report.status_lines
    puts "live evidence: #{evidence_path}"
    puts "per-RPC status: coverage/rpc/rpcs.tsv · summary: coverage/rpc/summary.json"
    notes.each { |n| puts "NOTE: #{n}" }
    unless problems.empty?
      problems.each { |p| puts "FAIL: #{p}" }
      abort "rpc:coverage failed (#{problems.size})"
    end
  end

  desc "RPC coverage drawn in SimpleCov's HTML interface: one file per package, one line per RPC (coverage/rpc/html)"
  task :coverage_html do
    abort "rpc:coverage_html needs a source checkout (#{rpc_tool} is not in the gem)" unless File.exist?(rpc_tool)
    require rpc_tool
    require File.join(rpc_root, "tools/rpc_coverage/html_report.rb")

    cfg = rpc_config.call
    backend = ENV["RPC_BACKEND"] || cfg.fetch("backend")
    registry_path = File.expand_path(ENV["RPC_REGISTRY"] || cfg.fetch("registry"), rpc_root)
    packages_path = File.expand_path(ENV["RPC_PACKAGES"] || cfg.fetch("packages"), rpc_root)
    registry = RpcCoverage.load_registry(registry_path)
    exclusions = RpcCoverage.load_exclusions(File.join(rpc_root, "data/rpc_coverage/exclusions.yml"))
    evidence_path = File.join(rpc_evidence_dir.call, "#{backend}.json")
    abort "no live evidence for #{backend} at #{evidence_path} (rake rpc:live BACKEND=#{backend} writes it)" unless File.exist?(evidence_path)
    evidence = RpcCoverage.load_evidence(evidence_path, backend)
    problems = RpcCoverage.registry_problems(registry) + RpcCoverage.exclusion_problems(exclusions, registry) +
               RpcCoverage.evidence_problems(evidence, secrets: [ ENV["RPMS_ACCESS"], ENV["RPMS_VERIFY"] ])
    abort "rpc:coverage_html: #{problems.join('; ')}" unless problems.empty?

    report = RpcCoverage.compute(registry: registry, declared: RpcCoverage.declared_names(rpc_root),
                                 evidence: evidence, exclusions: exclusions, backend: backend)
    index = RpcCoverage::Html.render(report, RpcCoverage::Html.load_packages(packages_path),
                                     File.join(rpc_root, "coverage/rpc"))
    abort "rpc:coverage_html: no report at #{index}" unless File.size?(index)
    puts report.one_liner
    puts "open #{index.delete_prefix("#{rpc_root}/")}"
  end

  desc "Run the read catalogue against one live CIA backend and merge into <rpms-diffs>/rpc-coverage/live/<BACKEND>.json"
  task :live do
    abort "rpc:live needs a source checkout (#{rpc_tool} is not in the gem)" unless File.exist?(rpc_tool)
    %w[BACKEND BROKER_PORT RPMS_ACCESS RPMS_VERIFY].each { |k| abort "rpc:live requires #{k}=" if ENV[k].to_s.empty? }
    abort "BACKEND= must be a plain label ([a-z0-9._-])" unless ENV["BACKEND"].match?(/\A[a-z0-9._-]+\z/)

    evidence = File.join(rpc_evidence_dir.call, "#{ENV['BACKEND']}.json")
    runner = File.join(rpc_root, "tools/rpc_coverage/live_runner.rb")
    sh({ "EVIDENCE" => evidence }, RbConfig.ruby, runner)
  end
end
