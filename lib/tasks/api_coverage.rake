# frozen_string_literal: true

# API coverage (rpms-rpc#358, ADR 0010 assertion 2): which public methods of the API modules a
# live spec proves, generated from lib/rpms_rpc/api/ and test/live/ on every run.
#
#   rake rpc:api_coverage [OUT=coverage/api/methods.json] [VERBOSE=1]
#
# Prints methods proven / public methods, per module; VERBOSE=1 adds one line per method (its RPCs
# and live specs). Writes the JSON documented in the README. Offline: no broker is reached.
# The implementation lives in tools/api_coverage/, which is not part of the gem.
namespace :rpc do
  api_root = File.expand_path("../..", __dir__)
  api_tool = File.join(api_root, "tools/api_coverage/api_coverage.rb")

  desc "Public API methods proven by a live spec (OUT= JSON path, VERBOSE=1 per method)"
  task :api_coverage do
    abort "rpc:api_coverage needs a source checkout (#{api_tool} is not in the gem)" unless File.exist?(api_tool)
    require api_tool
    require "fileutils"
    $LOAD_PATH.unshift(File.join(api_root, "lib"))
    require "rpms_rpc"

    report = ApiCoverage.build(api_root)
    entries = report[:entries]
    conflicts = ApiCoverage.shape_conflicts(entries)
    unless conflicts.empty?
      detail = conflicts.map do |group|
        shape = group.first[:shape]
        names = group.map { |e| "#{e[:module]}.#{e[:method]}" }.sort.join(", ")
        "#{shape[:verb]} #{shape[:path]} (#{names})"
      end
      abort "rpc:api_coverage: declared shapes share a verb and path: #{detail.join('; ')}"
    end

    out = File.expand_path(ENV["OUT"] || "coverage/api/methods.json", api_root)
    FileUtils.mkdir_p(File.dirname(out))
    File.write(out, JSON.pretty_generate(ApiCoverage.document(entries, registry_tag: report[:registry_tag])) + "\n")
    abort "rpc:api_coverage: wrote nothing to #{out}" unless File.size?(out)

    puts ApiCoverage.method_lines(entries) if ENV["VERBOSE"] == "1"
    puts ApiCoverage.report_lines(entries)
    puts "registry: #{report[:registry_tag]}"
    puts "per method: #{ApiCoverage.rel(out, api_root)}"
  end

  # The RPCs this release sends, per API module, for client.compatibility (rpms-rpc#366). Ships in
  # the gem; test/api_coverage/required_rpcs_test.rb fails until this is re-run after a change to
  # what a public method sends.
  desc "Write lib/rpms_rpc/required_rpcs.json: the RPCs each public API module sends (#366)"
  task :required_rpcs do
    abort "rpc:required_rpcs needs a source checkout (#{api_tool} is not in the gem)" unless File.exist?(api_tool)
    require api_tool
    $LOAD_PATH.unshift(File.join(api_root, "lib"))
    require "rpms_rpc"

    report = ApiCoverage.build(api_root)
    unresolved = report[:entries].reject { |e| e[:unresolved].empty? }
    abort "rpc:required_rpcs: #{unresolved.size} method(s) have RPCs static analysis cannot resolve; fix them first" unless unresolved.empty?

    doc = ApiCoverage.required_rpcs(report[:entries], build: report[:registry_tag])
    out = RpmsRpc::Compatibility::REQUIRED_PATH
    File.write(out, ApiCoverage.required_rpcs_json(doc))
    abort "rpc:required_rpcs: #{out} does not hold what was generated" unless JSON.parse(File.read(out)) == doc

    puts "#{ApiCoverage.rel(out, api_root)}: #{doc['modules'].values.flatten.uniq.size} RPCs over #{doc['modules'].size} modules, derived on #{doc['build']}"
  end
end
