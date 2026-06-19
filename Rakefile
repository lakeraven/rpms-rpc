# frozen_string_literal: true

require "bundler/setup"
require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.verbose = false
end

namespace :coverage do
  desc "Regenerate docs/RPC_COVERAGE.md"
  task :matrix do
    ruby "bin/build_coverage_matrix"
  end
end

task default: :test
