# frozen_string_literal: true

require "bundler/setup"
require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/live/**/*")
  t.verbose = false
end

# Live specs (ADR 0009): over the wire against a disposable container of the
# pinned build, or a stack over an SSM tunnel. Invoking this task means you
# meant to reach RPMS, so it FAILS, before loading a spec, unless BROKER_HOST,
# BROKER_PORT, RPMS_ACCESS, RPMS_VERIFY and PERSONA are set; and a run in which
# no live spec ran is never green. See test/live/live_helper.rb.
#
# BROKER_PROTOCOL (cia, the default, or xwb) picks the broker line and the
# specs written for it: test/live/*_test.rb for CIA, test/live/xwb/ for XWB.
require_relative "test/live/live_env"
namespace :test do
  Rake::TestTask.new(:live) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = FileList[LiveSpec::SPEC_GLOBS.fetch(LiveSpec.protocol, "")]
    t.verbose = false
  end

  task :live_settings do
    error = LiveSpec.protocol_error
    abort "rake test:live: #{error}" if error
    missing = LiveSpec.missing_env
    abort "rake test:live: #{LiveSpec.missing_env_message(missing)}" unless missing.empty?
    ENV["LIVE_RUN"] = "1" # the summary fails a run in which no live spec ran
  end
  task live: :live_settings
end

Dir.glob(File.expand_path("lib/tasks/*.rake", __dir__)).each { |r| load r }

namespace :coverage do
  desc "Regenerate docs/RPC_COVERAGE.md"
  task :matrix do
    ruby "bin/build_coverage_matrix"
  end
end

task default: :test
