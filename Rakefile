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
# BROKER_PROTOCOL (cia, the default, xwb or bmx) picks the broker line and the
# specs written for it: test/live/*_test.rb for CIA, test/live/xwb/ for XWB,
# test/live/bmx/ for BMX.
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

# Changelog fragments (changelog.d/): one file per PR, assembled into CHANGELOG.md at release.
namespace :changelog do
  fragments_dir = File.expand_path("changelog.d", __dir__)
  changelog = File.expand_path("CHANGELOG.md", __dir__)

  desc "Validate every changelog fragment in changelog.d/"
  task :check do
    require_relative "tools/changelog_fragments"
    puts "changelog:check: #{Fragments.check(fragments_dir)} fragment(s) valid"
  rescue Fragments::Error => e
    abort "changelog:check: #{e.message}"
  end

  desc "Insert the fragments under [Unreleased] in CHANGELOG.md and delete them (the release step commits)"
  task :assemble do
    require_relative "tools/changelog_fragments"
    result = Fragments.apply(changelog_path: changelog, dir: fragments_dir)
    if result.files.empty?
      puts "changelog:assemble: no fragments, CHANGELOG.md unchanged"
    else
      puts "changelog:assemble: wrote #{result.files.size} fragment(s) into CHANGELOG.md and deleted #{result.files.map { |f| File.basename(f) }.join(', ')}"
    end
  rescue Fragments::Error => e
    abort "changelog:assemble: #{e.message}"
  end
end

task default: :test
