# frozen_string_literal: true

# RPC coverage against ONE backend's registry (rpms-rpc#270).
#
#   rake rpc:coverage   offline, CI-safe: pinned registry x committed live evidence -> one number
#   rake rpc:coverage_html  the same report in SimpleCov's HTML interface, one file per package
#   rake rpc:exclusions regenerates the unreachable exclusions (no routine, no entry point, inactive,
#                       no context, out of order) from the pinned release's reach face, the
#                       <tag>-rpc_reach.txt rpms-ops publishes and conformance:pin commits (#278, #394)
#   rake rpc:live BACKEND=<label> BROKER_HOST= BROKER_PORT= RPMS_ACCESS= RPMS_VERIFY= [RPMS_CONTEXT=] [PERSONA=]
#                       runs the read catalogue against a live CIA broker and merges the result
#                       into <evidence dir>/<BACKEND>.json, or with PERSONA=programmer into
#                       <evidence dir>/<BACKEND>.programmer.json (#335). The headline reads only the first;
#                       the programmer file classifies what the least-privilege user could not reach.
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

  rpc_secrets = -> { [ ENV["RPMS_ACCESS"], ENV["RPMS_VERIFY"] ] }
  # The programmer persona's evidence beside <backend>.json, or nil when there is none (not an error).
  rpc_programmer = lambda do |evidence_path, backend|
    path = RpcCoverage.evidence_path(File.dirname(evidence_path), backend, "programmer")
    next [ nil, [] ] unless File.exist?(path)

    prog = RpcCoverage.load_evidence(path, backend)
    [ prog, RpcCoverage.evidence_problems(prog, secrets: rpc_secrets.call, persona: "programmer") ]
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
    programmer, programmer_problems = rpc_programmer.call(evidence_path, backend)
    problems = RpcCoverage.registry_problems(registry) +
               RpcCoverage.exclusion_problems(exclusions, registry, evidence: evidence) +
               RpcCoverage.evidence_problems(evidence, secrets: rpc_secrets.call, persona: RpcCoverage::DEFAULT_PERSONA) +
               programmer_problems
    report = RpcCoverage.compute(registry: registry, declared: RpcCoverage.declared_names(rpc_root),
                                 evidence: evidence, exclusions: exclusions, backend: backend, programmer: programmer)
    problems += RpcCoverage.gate_problems(report, max_unregistered: cfg["max_unregistered"])
    notes = RpcCoverage.coverage_notes(report, minimum_percent: cfg["minimum_percent"])

    out = File.join(rpc_root, "coverage/rpc")
    FileUtils.mkdir_p(out)
    File.write(File.join(out, "rpcs.tsv"), report.tsv)
    File.write(File.join(out, "summary.json"), JSON.pretty_generate(report.to_h.merge(problems: problems, notes: notes)) + "\n")

    puts report.one_liner
    puts report.status_lines
    puts report.programmer_lines
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
    programmer, programmer_problems = rpc_programmer.call(evidence_path, backend)
    problems = RpcCoverage.registry_problems(registry) + RpcCoverage.exclusion_problems(exclusions, registry, evidence: evidence) +
               RpcCoverage.evidence_problems(evidence, secrets: rpc_secrets.call, persona: RpcCoverage::DEFAULT_PERSONA) +
               programmer_problems
    abort "rpc:coverage_html: #{problems.join('; ')}" unless problems.empty?

    report = RpcCoverage.compute(registry: registry, declared: RpcCoverage.declared_names(rpc_root),
                                 evidence: evidence, exclusions: exclusions, backend: backend, programmer: programmer)
    index = RpcCoverage::Html.render(report, RpcCoverage::Html.load_packages(packages_path),
                                     File.join(rpc_root, "coverage/rpc"))
    abort "rpc:coverage_html: no report at #{index}" unless File.size?(index)
    puts report.one_liner
    puts report.programmer_lines.first
    puts "open #{index.delete_prefix("#{rpc_root}/")}"
  end

  desc "Regenerate the unreachable RPCs in data/rpc_coverage/exclusions.yml from the pinned release's reach face " \
       "(data/inventories/<release>/<release>-rpc_reach.txt; release from data/rpc_coverage/config.yml)"
  task :exclusions do
    abort "rpc:exclusions needs a source checkout (#{rpc_tool} is not in the gem)" unless File.exist?(rpc_tool)
    require rpc_tool
    require "rpms_rpc/conformance/inventory_lock"

    cfg = rpc_config.call
    tag = cfg.fetch("release")
    lock_class = RpmsRpc::Conformance::InventoryLock
    lock = lock_class.load(File.join(rpc_root, "data/fingerprints", lock_class::DEFAULT_PATH))
    entry = lock[tag] or abort "rpc:exclusions: #{tag} is not pinned (rake conformance:pin RELEASE=#{tag})"
    # The reach face is read only after its bytes are proven to be the pinned ones.
    inv = begin
      lock_class.verify_dir(tag, File.join(rpc_root, "data/inventories", tag))
    rescue lock_class::Error => e
      abort "rpc:exclusions: the pinned files for #{tag} fail verification: #{e.message}"
    end
    reach_file = "#{tag}-rpc_reach.txt"
    unless inv.shas[reach_file] == entry.dig("assets", reach_file)
      abort "rpc:exclusions: #{reach_file} sha256 #{inv.shas[reach_file]} is not the pinned #{entry.dig('assets', reach_file).inspect}"
    end

    surface = inv.surface
    registry = RpcCoverage.load_registry(File.expand_path(cfg.fetch("registry"), rpc_root))
    problems = RpcCoverage.registry_problems(registry)
    problems << "registry #{registry.tag} is not the release #{tag}" unless registry.tag == tag
    abort "rpc:exclusions: #{problems.join('; ')}" unless problems.empty?

    path = File.join(rpc_root, "data/rpc_coverage/exclusions.yml")
    unreachable = RpcCoverage.unreachable_from_surface(surface)
    result = RpcCoverage.regenerate_exclusions(RpcCoverage.load_exclusions(path), unreachable, registry)
    source = [
      "reach: data/inventories/#{tag}/#{reach_file}",
      "reach sha256: #{inv.shas[reach_file]} (pinned in data/fingerprints/rpms-ops.lock.yml)",
      "reach classes: #{surface.reach_counts.map { |k, v| "#{k}=#{v}" }.join(' ')}",
      "registry: #{tag} (#{registry.names.size} names)",
      "regenerate: bundle exec rake rpc:exclusions"
    ]
    File.write(path, RpcCoverage.exclusions_yaml(result.exclusions, source: source))

    check = RpcCoverage.exclusion_problems(RpcCoverage.load_exclusions(path), registry)
    abort "rpc:exclusions wrote #{path} but it fails its own gate: #{check.first(3).join('; ')}" unless check.empty?
    puts "not callable on #{tag}: #{unreachable.size}; not in the registry (residue, not excluded): #{result.not_in_registry.size}"
    result.not_in_registry.each { |n| puts "  residue: #{n}" }
    result.exclusions.values.tally.sort.each { |r, n| puts format("  %-24s %5d", r, n) }
    # An RPC the gem sends that the build does not let a client call is the callable gate's failure
    # (test/rpms_rpc/callable_rpc_names_test.rb), not only a smaller denominator: say so.
    sent = RpcCoverage.declared_names(rpc_root)
    result.exclusions.each do |name, reason|
      puts "  WARNING: #{name} (#{reason}) is sent by the gem (#{sent[name].first}); see data/fingerprints/uncallable_exceptions.yml" if sent.key?(name)
    end
    puts "wrote #{path.delete_prefix("#{rpc_root}/")}: #{result.exclusions.size} exclusions"
  end

  desc "Run the read catalogue against one live CIA backend and merge into <rpms-diffs>/rpc-coverage/live/<BACKEND>.json"
  task :live do
    abort "rpc:live needs a source checkout (#{rpc_tool} is not in the gem)" unless File.exist?(rpc_tool)
    %w[BACKEND BROKER_PORT RPMS_ACCESS RPMS_VERIFY].each { |k| abort "rpc:live requires #{k}=" if ENV[k].to_s.empty? }
    abort "BACKEND= must be a plain label ([a-z0-9._-])" unless ENV["BACKEND"].match?(/\A[a-z0-9._-]+\z/)
    abort "BACKEND= must not end in .programmer (PERSONA=programmer names that file)" if ENV["BACKEND"].end_with?(".programmer")
    require rpc_tool
    persona = begin
      RpcCoverage.persona(ENV["PERSONA"])
    rescue RpcCoverage::Error => e
      abort "rpc:live: #{e.message}"
    end

    evidence = RpcCoverage.evidence_path(rpc_evidence_dir.call, ENV["BACKEND"], persona)
    runner = File.join(rpc_root, "tools/rpc_coverage/live_runner.rb")
    sh({ "EVIDENCE" => evidence, "PERSONA" => persona }, RbConfig.ruby, runner)
  end
end
