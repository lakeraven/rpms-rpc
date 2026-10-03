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
# pinned build. Skipped unless BROKER_HOST, BROKER_PORT, RPMS_ACCESS,
# RPMS_VERIFY and PERSONA are set; see test/live/live_helper.rb.
namespace :test do
  Rake::TestTask.new(:live) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = FileList["test/live/**/*_test.rb"]
    t.verbose = false
  end
end

Dir.glob(File.expand_path("lib/tasks/*.rake", __dir__)).each { |r| load r }

namespace :coverage do
  desc "Regenerate docs/RPC_COVERAGE.md"
  task :matrix do
    ruby "bin/build_coverage_matrix"
  end
end

task default: :test
