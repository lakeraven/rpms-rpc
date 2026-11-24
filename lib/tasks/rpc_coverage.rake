# frozen_string_literal: true

# RPC coverage against ONE backend's registry (rpms-rpc#270).
#
#   rake rpc:coverage   offline. The headline: the pilot scenarios (data/rpc_coverage/pilot.yml) whose calls are all
#                       proven live as the role that plays them, from the live specs' summaries (`proves` declarations,
#                       coverage/live/<role>.json or LIVE_SUMMARY_DIR; #818), and the registered RPCs a role's live spec
#                       got an answer to. Below it, the release under test's registry x rake rpc:live evidence -> one number
#   rake rpc:coverage_html  the same report in SimpleCov's HTML interface, one file per package
#   rake rpc:exclusions prints the exclusions the release under test computes: the unreachable ones (no
#                       routine, no entry point, inactive, no context, out of order) from its reach classes
#                       in <tag>-rpcs.json (#278, #394, #406, #724), plus the reviewed ones in
#                       data/rpc_coverage/exclusions.yml. Nothing is written.
#   rake rpc:cases CASES=<cases.jsonl> ROLE=<role> BROKER_HOST= BROKER_PORT= [RPMS_ACCESS= RPMS_VERIFY=] [OUT=]
#                       runs openrpms' wire-level cases (data, not API calls; openrpms#834) and
#                       exits 1 unless every case of the role gives its expected verdict
#   rake rpc:live BACKEND=<label> ROLE=<role> BROKER_HOST= BROKER_PORT= [RPMS_ACCESS= RPMS_VERIFY=] [RPMS_CONTEXT=]
#                       runs the read catalogue against a live CIA broker as the test role and merges the
#                       result into <evidence dir>/<BACKEND>.<ROLE>.json. The pair is the role's published
#                       one unless RPMS_ACCESS/RPMS_VERIFY give the target's (ROLE=operator needs RPMS_VERIFY).
#                       The run is refused unless the account is the role's and holds XUPROGMODE exactly
#                       when the role's row says so. The number reads every role's file but the operator's;
#                       the operator's classifies what the other roles could not reach. Files written
#                       before roles (<BACKEND>.json, <BACKEND>.programmer.json) are read as legacy.
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
  # The pilot scenarios' report from the live specs' summaries: LIVE_SUMMARY_DIR (any depth, so a directory of CI
  # artifacts works), else coverage/live, against data/rpc_coverage/pilot.yml and the specs' `proves` lines.
  rpc_scenarios = lambda do
    require File.join(rpc_root, "tools/rpc_coverage/scenarios.rb")
    require File.join(rpc_root, "test/live/live_env.rb")
    dir = File.expand_path(RpmsRpc::LiveSummary.dir(ENV), rpc_root)
    RpcCoverage::Scenarios.report(pilot: RpcCoverage::Scenarios.load_pilot(File.join(rpc_root, "data/rpc_coverage/pilot.yml")),
                                  plan: LiveSpec.scenario_plan(root: rpc_root),
                                  summaries: RpcCoverage::Scenarios.load_summaries(dir))
  end

  # Every role's evidence for the backend (RpcCoverage.coverage_inputs), or abort naming what writes it.
  rpc_evidence = lambda do |backend|
    dir = rpc_evidence_dir.call
    found = RpcCoverage.coverage_inputs(dir, backend, secrets: rpc_secrets.call)
    abort "no live evidence for #{backend} in #{dir} (rake rpc:live BACKEND=#{backend} ROLE=<role> writes it)" unless found

    found
  end

  desc "RPC coverage of the openrpms release under test (RPC_REGISTRY=, RPC_BACKEND= override)"
  task :coverage do
    abort "rpc:coverage needs a source checkout (#{rpc_tool} is not in the gem)" unless File.exist?(rpc_tool)
    require rpc_tool
    require "fileutils"
    require "json"

    cfg = rpc_config.call
    backend = ENV["RPC_BACKEND"] || cfg.fetch("backend")
    inputs = rpc_inputs.call("coverage")
    registry = inputs[:registry]
    exclusions = inputs[:exclusions]

    # The headline: the pilot scenarios, as the roles that play them, from the live specs' summaries (#818).
    out = File.join(rpc_root, "coverage/rpc")
    FileUtils.mkdir_p(out)
    scenarios = rpc_scenarios.call
    counts = RpcCoverage::Scenarios.rpc_counts(scenarios, registry.names)
    puts scenarios.lines
    puts "registered RPCs a role's live spec got an answer to: #{counts[:roles]} of #{counts[:registered]} on #{registry.tag} " \
         "(answered only as the operator, counted nowhere: #{counts[:operator_only]})"
    File.write(File.join(out, "scenarios.json"), JSON.pretty_generate(scenarios.to_h.merge(rpcs: counts)) + "\n")
    puts "per-scenario status: coverage/rpc/scenarios.json"
    puts
    puts "the read catalogue (rake rpc:live):"

    live = rpc_evidence.call(backend)
    evidence = live[:evidence]
    problems = RpcCoverage.registry_problems(registry) + inputs[:problems] +
               RpcCoverage.exclusion_problems(exclusions, registry, evidence: evidence) + live[:problems]
    report = RpcCoverage.compute(registry: registry, declared: RpcCoverage.declared_names(rpc_root),
                                 evidence: evidence, exclusions: exclusions, backend: backend,
                                 operator: live[:operator], as: live[:as], operator_as: live[:operator_as])
    problems += RpcCoverage.gate_problems(report, max_unregistered: cfg["max_unregistered"])
    notes = RpcCoverage.coverage_notes(report, minimum_percent: cfg["minimum_percent"])

    File.write(File.join(out, "rpcs.tsv"), report.tsv)
    File.write(File.join(out, "summary.json"), JSON.pretty_generate(report.to_h.merge(problems: problems, notes: notes)) + "\n")

    puts report.one_liner
    puts report.status_lines
    puts report.operator_lines
    puts "live evidence: #{live[:paths].join(', ')}"
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
    live = rpc_evidence.call(backend)
    evidence = live[:evidence]
    problems = RpcCoverage.registry_problems(registry) + inputs[:problems] + RpcCoverage.exclusion_problems(exclusions, registry, evidence: evidence) +
               live[:problems]
    abort "rpc:coverage_html: #{problems.join('; ')}" unless problems.empty?

    report = RpcCoverage.compute(registry: registry, declared: RpcCoverage.declared_names(rpc_root),
                                 evidence: evidence, exclusions: exclusions, backend: backend,
                                 operator: live[:operator], as: live[:as], operator_as: live[:operator_as])
    index = RpcCoverage::Html.render(report, RpcCoverage::Html.load_packages(packages_path),
                                     File.join(rpc_root, "coverage/rpc"))
    abort "rpc:coverage_html: no report at #{index}" unless File.size?(index)
    puts report.one_liner
    puts report.operator_lines.first
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
    %w[BACKEND BROKER_PORT].each { |k| abort "rpc:live requires #{k}=" if ENV[k].to_s.empty? }
    abort "BACKEND= must be a plain label ([a-z0-9._-])" unless ENV["BACKEND"].match?(/\A[a-z0-9._-]+\z/)
    require rpc_tool
    begin
      RpcCoverage.sign_on_pair(RpcCoverage.run_role(ENV), ENV)
    rescue RpcCoverage::Error => e
      abort "rpc:live: #{e.message}"
    end
    taken = (RpcCoverage::ROLES.names.map(&:to_s) + RpcCoverage::LEGACY_PERSONAS).find { |r| ENV["BACKEND"].end_with?(".#{r}") }
    abort "BACKEND= must not end in .#{taken} (a role's evidence file is named <BACKEND>.<role>.json)" if taken

    runner = File.join(rpc_root, "tools/rpc_coverage/live_runner.rb")
    sh({ "EVIDENCE_DIR" => rpc_evidence_dir.call, "EVIDENCE" => nil }, RbConfig.ruby, runner)
  end

  desc "Run openrpms' wire-level cases (CASES=<data/conformance/cases.jsonl>) against one live CIA backend (openrpms#834)"
  task :cases do
    runner = File.join(rpc_root, "tools/rpc_coverage/run_cases.rb")
    abort "rpc:cases needs a source checkout (#{runner} is not in the gem)" unless File.exist?(runner)
    %w[CASES BROKER_PORT ROLE].each { |k| abort "rpc:cases requires #{k}=" if ENV[k].to_s.empty? }
    sh(RbConfig.ruby, runner)
  end
end
