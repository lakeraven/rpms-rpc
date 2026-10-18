# frozen_string_literal: true

# A release may be tagged only when live summaries prove a green run against
# the single pinned rpms-ops build (rpms-rpc#361, ADR 0010 assertion 10).
# This task runs before Bundler tags or pushes. It does not tag, publish,
# or read the build off a server.
namespace :release do
  desc "Refuse to tag unless live summaries are green for the pinned build"
  task :live_guard do
    require_relative "../rpms_rpc/live_summary"

    root = File.expand_path("../..", __dir__)
    lock_path = File.join(root, "data/fingerprints/rpms-ops.lock.yml")
    begin
      build = RpmsRpc::LiveSummary.pinned_build(lock_path)
    rescue StandardError => e
      abort "release:live_guard: refusing to release: #{e.message}"
    end

    dir = File.expand_path(RpmsRpc::LiveSummary.dir, root)
    ok, reasons = RpmsRpc::LiveSummary.check(dir: dir, build: build)
    if ok
      puts "release:live_guard: OK #{build}"
    else
      abort [ "release:live_guard: refusing to release:", *reasons ].join("\n")
    end
  end
end

# Bundler defines `release` before lib/tasks is loaded. enhance appends, and
# a prerequisite runs in list order, so the guard has to lead: otherwise
# guard_clean, the tag and the push have already run when a bad summary refuses.
if Rake::Task.task_defined?("release")
  release = Rake::Task["release"]
  release.enhance([ "release:live_guard" ])
  prereqs = release.prerequisites
  prereqs.unshift(prereqs.delete("release:live_guard"))
end
