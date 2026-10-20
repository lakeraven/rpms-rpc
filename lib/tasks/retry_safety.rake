# frozen_string_literal: true

# Retry-safety classification (rpms-rpc#110). The gem never retries. This task
# checks lib/rpms_rpc/retry_safety.yml against the public API.
#
#   rake rpc:retry_safety
#
# Offline: no broker is reached. The method list comes from tools/api_coverage/,
# which is not part of the gem.
namespace :rpc do
  root = File.expand_path("../..", __dir__)
  tool = File.join(root, "tools/api_coverage/api_coverage.rb")

  desc "Check the retry-safety class of every public API method"
  task :retry_safety do
    abort "rpc:retry_safety needs a source checkout (#{tool} is not in the gem)" unless File.exist?(tool)
    require tool
    $LOAD_PATH.unshift(File.join(root, "lib"))
    require "rpms_rpc"

    pairs = ApiCoverage.public_methods_of(RpmsRpc, File.join(root, "lib/rpms_rpc/api"))
    labels = pairs.map { |mod, name| "#{mod.name}.#{name}" }
    path = ENV["RETRY_SAFETY_TABLE"]
    table = path ? RpmsRpc::RetrySafety.load(path) : RpmsRpc::RetrySafety.table
    lint = RpmsRpc::RetrySafety.lint(labels, table)
    missing = lint[:unclassified]
    extra = lint[:stale]
    missing.each { |label| puts "unclassified: #{label}" }
    extra.each { |key| puts "stale: #{key}" }
    abort "rpc:retry_safety failed (#{missing.size + extra.size})" unless missing.empty? && extra.empty?

    reads = table.count { |_, value| value == :read }
    writes = table.count { |_, value| value == :non_idempotent_write }
    puts "retry safety: #{labels.size} public methods classified (#{reads} read, #{writes} non_idempotent_write)"
  end
end
