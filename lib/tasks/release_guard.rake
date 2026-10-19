# frozen_string_literal: true

# A release may be tagged only when live summaries prove a green run against
# the single pinned rpms-ops build (rpms-rpc#361, ADR 0010 assertion 10), of
# the very files the gem ships (rpms-rpc#441).
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

    begin
      source = RpmsRpc::LiveSummary.source_fingerprint(root)
    rescue StandardError => e
      abort "release:live_guard: refusing to release: #{e.message}"
    end

    dir = File.expand_path(RpmsRpc::LiveSummary.dir, root)
    ok, reasons = RpmsRpc::LiveSummary.check(dir: dir, build: build, source: source)
    if ok
      puts "release:live_guard: OK #{build} on source #{source} (build not verified against the server)"
      RpmsRpc::LiveSummary.outcomes(dir).each { |line| puts "  #{line}" }
    else
      abort [ "release:live_guard: refusing to release:", *reasons ].join("\n")
    end
  end
end

# Written before test:live loads a spec, stamped with a fresh LIVE_RUN_ID
# the spec process inherits. A crash (SyntaxError, a raised exception) then
# leaves pending on disk, and the guard refuses it instead of trusting the
# previous green file. Only a summary whose run id matches that marker may
# replace it, so a spec invoked by path cannot paint a red run green. The
# marker depends on test:live_settings, which sets LIVE_RUN=1 and refuses an
# incomplete broker env. List order alone does not enforce this under rake -m;
# without the dependency the writer can stay quiet and a stale file survives.
# The task then reads the marker back and aborts when it is not on disk.
namespace :test do
  desc "Mark this live run's summary pending, with a run id, before specs load"
  task live_summary_pending: "test:live_settings" do
    require "securerandom"
    require_relative "../rpms_rpc/live_summary"

    root = File.expand_path("../..", __dir__)
    summary = RpmsRpc::LiveSummary
    begin
      identity = summary.run_identity(ENV, root: root)
      dir = File.expand_path(summary.dir, root)
      path = summary.path_for(dir, persona: identity[:persona], protocol: identity[:protocol])
      token = SecureRandom.hex(8)
      ENV["LIVE_RUN_ID"] = token
      summary.mark_pending(
        path,
        persona: identity[:persona],
        protocol: identity[:protocol],
        build: identity[:build],
        build_source: identity[:build_source],
        source: identity[:source],
        run_id: token
      )
      abort "test:live_summary_pending: no pending marker at #{path}; refusing to run" unless summary.pending_for?(path, token)
    rescue ArgumentError => e
      abort "test:live_summary_pending: #{e.message}; check PERSONA and BROKER_PROTOCOL"
    end
  end
end

# The marker is a prerequisite of the live action; its own dependency above
# makes settings finish first even under parallel prerequisite execution.
Rake::Task["test:live"].enhance([ "test:live_summary_pending" ]) if Rake::Task.task_defined?("test:live")

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
