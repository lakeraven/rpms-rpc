# frozen_string_literal: true

# RPC coverage against ONE backend's registry (rpms-rpc#270).
#
#   rake rpc:coverage   offline: the release under test's registry x live evidence -> one number
#   rake rpc:coverage_html  the same report in SimpleCov's HTML interface, one file per package
#   rake rpc:exclusions prints the exclusions the release under test computes: the unreachable ones (no
#                       routine, no entry point, inactive, no context, out of order) from its reach classes
#                       in <tag>-rpcs.json (#278, #394, #406, #724), plus the reviewed ones in
#                       data/rpc_coverage/exclusions.yml. Nothing is written.
#   rake rpc:cases CASES=<cases.jsonl> BROKER_HOST= BROKER_PORT= RPMS_ACCESS= RPMS_VERIFY= [PERSONA=] [OUT=]
#                       runs openrpms' wire-level cases (data, not API calls; openrpms#834) and
#                       exits 1 unless every case of the persona gives its expected verdict
#   rake rpc:live BACKEND=<label> BROKER_HOST= BROKER_PORT= RPMS_ACCESS= RPMS_VERIFY= [RPMS_CONTEXT=] [PERSONA=]
#                       runs the read catalogue against a live CIA broker and merges the result
#                       into <evidence dir>/<BACKEND>.json, or, when the signed-on user holds XUPROGMODE,
#                       into <evidence dir>/<BACKEND>.programmer.json (#335). The run is labelled by who
#                       signed on (#397); PERSONA= is only an expectation that fails the run when unmet.
#                       The headline reads only the first file; the programmer file classifies what the
#                       least-privilege user could not reach.
#
# Live evidence is a build-specific artifact, so it lives in lakeraven/rpms-diffs, not here:
# <evidence dir> is rpc-coverage/live/ in an rpms-diffs checkout, by default the sibling of this
# repo (../rpms-diffs). Override it with RPMS_DIFFS_DIR= (the checkout) or RPC_EVIDENCE_DIR= (the dir).
#
# Config: data/rpc_coverage/config.yml (backend, minimum_percent, max_unregistered). The registry is the
# openrpms release under test (`rake openrpms:fetch`, rpms-rpc#724); RPC_REGISTRY= / RPC_PACKAGES= override it.
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
# The release under test, its registry (RPC_REGISTRY= overrides), its packages (RPC_PACKAGES=), and every
# exclusion: the reviewed ones in exclusions.yml plus the ones its reach classes compute. Aborts, naming
# the task to run, when no release has been fetched.
rpc_inputs = lambda do |task|
  require "rpms_rpc/conformance/release_inventory"
  release = RpmsRpc::Conformance::ReleaseInventory
  inv = begin
    release.current
  rescue release::Error => e
    abort "rpc:#{task}: #{e.message}"
  end
  registry = RpcCoverage.load_registry(File.expand_path(ENV["RPC_REGISTRY"] || inv.rpcs_json, rpc_root))
  packages = File.expand_path(ENV["RPC_PACKAGES"] || inv.packages_dump, rpc_root)
  reviewed = RpcCoverage.load_exclusions(File.join(rpc_root, "data/rpc_coverage/exclusions.yml"))
  computed = RpcCoverage.exclusions_for(reviewed, registry.surface || inv.surface, registry)
  { release: inv, registry: registry, packages: packages, reviewed: reviewed, computed: computed,
    exclusions: computed.exclusions, problems: RpcCoverage.reviewed_problems(reviewed) }
end
  # The programmer persona's evidence beside <backend>.json, or nil when there is none (not an error).
  rpc_programmer = lambda do |evidence_path, backend|
    path = RpcCoverage.evidence_path(File.dirname(evidence_path), backend, "programmer")
    next [ nil, [] ] unless File.exist?(path)

    prog = RpcCoverage.load_evidence(path, backend)
    [ prog, RpcCoverage.evidence_problems(prog, secrets: rpc_secrets.call, persona: "programmer") ]
  end

  desc "RPC coverage of the openrpms release under test (RPC_REGISTRY=, RPC_BACKEND= override)"
  task :coverage do
    abort "rpc:coverage needs a source checkout (#{rpc_tool} is not in the gem)" unless File.exist?(rpc_tool)
    require rpc_tool
    require "fileutils"
    require "json"

    cfg = rpc_config.call
    backend = ENV["RPC_BACKEND"] || cfg.fetch("backend")
    evidence_path = File.join(rpc_evidence_dir.call, "#{backend}.json")
    abort "no live evidence for #{backend} at #{evidence_path} (rake rpc:live BACKEND=#{backend} writes it)" unless File.exist?(evidence_path)

    inputs = rpc_inputs.call("coverage")
    registry = inputs[:registry]
    exclusions = inputs[:exclusions]
    evidence = RpcCoverage.load_evidence(evidence_path, backend)
    programmer, programmer_problems = rpc_programmer.call(evidence_path, backend)
    problems = RpcCoverage.registry_problems(registry) + inputs[:problems] +
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
    inputs = rpc_inputs.call("coverage_html")
    registry = inputs[:registry]
    packages_path = inputs[:packages]
    exclusions = inputs[:exclusions]
    evidence_path = File.join(rpc_evidence_dir.call, "#{backend}.json")
    abort "no live evidence for #{backend} at #{evidence_path} (rake rpc:live BACKEND=#{backend} writes it)" unless File.exist?(evidence_path)
    evidence = RpcCoverage.load_evidence(evidence_path, backend)
    programmer, programmer_problems = rpc_programmer.call(evidence_path, backend)
    problems = RpcCoverage.registry_problems(registry) + inputs[:problems] + RpcCoverage.exclusion_problems(exclusions, registry, evidence: evidence) +
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

  desc "Print the exclusions the openrpms release under test computes (reach classes) plus the reviewed ones " \
       "in data/rpc_coverage/exclusions.yml; writes nothing"
  task :exclusions do
    abort "rpc:exclusions needs a source checkout (#{rpc_tool} is not in the gem)" unless File.exist?(rpc_tool)
    require rpc_tool

    inputs = rpc_inputs.call("exclusions")
    inv = inputs[:release]
    registry = inputs[:registry]
    problems = RpcCoverage.registry_problems(registry) + inputs[:problems] +
               RpcCoverage.exclusion_problems(inputs[:exclusions], registry)
    abort "rpc:exclusions: #{problems.join('; ')}" unless problems.empty?

    result = inputs[:computed]
    puts "release under test: #{inv.tag} (#{registry.names.size} names; reach classes " \
         "#{inv.surface.reach_counts.map { |k, v| "#{k}=#{v}" }.join(' ')})"
    puts "excluded: #{result.exclusions.size} (#{inputs[:reviewed].size} reviewed); not in the registry (residue, not excluded): #{result.not_in_registry.size}"
    result.not_in_registry.each { |n| puts "  residue: #{n}" }
    result.exclusions.values.tally.sort.each { |r, n| puts format("  %-24s %5d", r, n) }
    # An RPC the gem sends that the build does not let a client call is the callable gate's failure
    # (test/rpms_rpc/callable_rpc_names_test.rb), not only a smaller denominator: say so.
    sent = RpcCoverage.declared_names(rpc_root)
    result.exclusions.each do |name, reason|
      puts "  WARNING: #{name} (#{reason}) is sent by the gem (#{sent[name].first}); see data/fingerprints/uncallable_exceptions.yml" if sent.key?(name)
    end
  end

  desc "Run the read catalogue against one live CIA backend and merge into <rpms-diffs>/rpc-coverage/live/<BACKEND>.json"
  task :live do
    abort "rpc:live needs a source checkout (#{rpc_tool} is not in the gem)" unless File.exist?(rpc_tool)
    %w[BACKEND BROKER_PORT RPMS_ACCESS RPMS_VERIFY].each { |k| abort "rpc:live requires #{k}=" if ENV[k].to_s.empty? }
    abort "BACKEND= must be a plain label ([a-z0-9._-])" unless ENV["BACKEND"].match?(/\A[a-z0-9._-]+\z/)
    abort "BACKEND= must not end in .programmer (a programmer sign-on names that file)" if ENV["BACKEND"].end_with?(".programmer")
    require rpc_tool
    begin
      RpcCoverage.expected_persona(ENV["PERSONA"])
    rescue RpcCoverage::Error => e
      abort "rpc:live: #{e.message}"
    end

    # The runner picks the file once it knows who signed on (#397).
    runner = File.join(rpc_root, "tools/rpc_coverage/live_runner.rb")
    sh({ "EVIDENCE_DIR" => rpc_evidence_dir.call, "EVIDENCE" => nil }, RbConfig.ruby, runner)
  end

  desc "Run openrpms' wire-level cases (CASES=<data/conformance/cases.jsonl>) against one live CIA backend (openrpms#834)"
  task :cases do
    runner = File.join(rpc_root, "tools/rpc_coverage/run_cases.rb")
    abort "rpc:cases needs a source checkout (#{runner} is not in the gem)" unless File.exist?(runner)
    %w[CASES BROKER_PORT RPMS_ACCESS RPMS_VERIFY].each { |k| abort "rpc:cases requires #{k}=" if ENV[k].to_s.empty? }
    sh(RbConfig.ruby, runner)
  end
end
