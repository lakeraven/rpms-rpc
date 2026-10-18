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
      sources = RpmsRpc::LiveSummary.build_sources(dir).join(", ")
      puts "release:live_guard: OK #{build} (#{sources}, not verified against the server)"
    else
      abort [ "release:live_guard: refusing to release:", *reasons ].join("\n")
    end
  end
end

# Written before test:live loads a spec. A crash (SyntaxError, a raised
# exception) then leaves pending on disk, and the guard refuses it instead
# of trusting the previous green file. The marker follows test:live_settings,
# which sets LIVE_RUN=1 and refuses an incomplete broker env; without that
# the writer stays quiet and the stale file would survive.
namespace :test do
  desc "Mark this live run's summary pending before specs load"
  task :live_summary_pending do
    require_relative "../rpms_rpc/live_summary"

    root = File.expand_path("../..", __dir__)
    summary = RpmsRpc::LiveSummary
    begin
      identity = summary.run_identity(ENV, root: root)
      dir = File.expand_path(summary.dir, root)
      path = summary.path_for(dir, persona: identity[:persona], protocol: identity[:protocol])
      summary.mark_pending(
        path,
        persona: identity[:persona],
        protocol: identity[:protocol],
        build: identity[:build],
        build_source: identity[:build_source]
      )
    rescue ArgumentError => e
      abort "test:live_summary_pending: #{e.message}; check PERSONA and BROKER_PROTOCOL"
    end
  end
end

# Appended, so it runs after test:live_settings. If that settings task exists
# but is not yet a prerequisite, link it first: Rake treats a bare argument
# list as task arguments, not prerequisites, and the marker writes nothing
# unless LIVE_RUN is already set.
if Rake::Task.task_defined?("test:live")
  live = Rake::Task["test:live"]
  if Rake::Task.task_defined?("test:live_settings") && !live.prerequisites.include?("test:live_settings")
    live.enhance([ "test:live_settings" ])
  end
  live.enhance([ "test:live_summary_pending" ])
end

# Bundler defines `release` before lib/tasks is loaded. enhance appends, and
# a prerequisite runs in list order, so the guard has to lead: otherwise
# guard_clean, the tag and the push have already run when a bad summary refuses.
# The push tasks are guarded on their own, so invoking one directly cannot
# skip the check. Rake runs a task once per invocation, so `rake release`
# still runs the guard once.
%w[release release:source_control_push release:rubygem_push].each do |name|
  next unless Rake::Task.task_defined?(name)

  task = Rake::Task[name]
  task.enhance([ "release:live_guard" ])
  prereqs = task.prerequisites
  prereqs.unshift(prereqs.delete("release:live_guard"))
end
