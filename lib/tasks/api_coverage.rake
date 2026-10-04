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
    out = File.expand_path(ENV["OUT"] || "coverage/api/methods.json", api_root)
    FileUtils.mkdir_p(File.dirname(out))
    File.write(out, JSON.pretty_generate(ApiCoverage.document(entries, registry_tag: report[:registry_tag])) + "\n")
    abort "rpc:api_coverage: wrote nothing to #{out}" unless File.size?(out)

    puts ApiCoverage.method_lines(entries) if ENV["VERBOSE"] == "1"
    puts ApiCoverage.report_lines(entries)
    puts "registry: #{report[:registry_tag]}"
    puts "per method: #{ApiCoverage.rel(out, api_root)}"
  end
end
