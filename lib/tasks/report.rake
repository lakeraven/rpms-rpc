# frozen_string_literal: true

# Daily picture of the gem against a broker (rpms-rpc#365).
#
#   rake report:daily
#   FRESH=1 DRY_RUN=1 rake report:daily
#   FRESH=1 rake report:daily
#
# Existing broker: BROKER_HOST, BROKER_PORT, and optional BUILD.
# Fresh container: FRESH=1, optional DRY_RUN=1. The image is the newest
# published bcer-*-ydb release of lakeraven/rpms-ops.
# Sign-on: PROV123_ACCESS, PROV123_VERIFY, SYS123_ACCESS, SYS123_VERIFY.
# Those values are handed only to that persona's rake test:live child.
# Output: <rpms-diffs>/rpc-coverage/daily/<date>-<build>.md
# (RPMS_DIFFS_DIR selects the checkout). The task exits with the report status.
namespace :report do
  desc "Run rake test and rake test:live for PROV123 and SYS123, and write rpc-coverage/daily/<date>-<build>.md"
  task :daily do
    require "rpms_rpc/daily_report"

    report = RpmsRpc::DailyReport
    root = File.expand_path("../..", __dir__)
    env = ENV.to_h
    diffs = report.rpms_diffs_dir(env, root: root)
    orchestrator = report::Orchestrator.new(
      root: root,
      env: env,
      releases: report::GhReleases.new(root: root),
      runner: report::ProcessRunner.new,
      docker: report::DockerCli.new,
      broker_probe: report::CiaBrokerProbe.new,
      clock: report::Clock.new,
      port_picker: report::LoopbackPortPicker.new,
      writer: report::FileWriter.new,
      summary_writer: report::StdoutWriter.new,
      rpms_diffs_dir: diffs,
      pinned_release: report.pinned_release(root: root),
      rpms_rpc_commit: report.rpms_rpc_commit(root: root),
      coverage: report.coverage_headline(root: root, env: env)
    )
    begin
      status = orchestrator.run
    rescue report::Orchestrator::OutputDirectoryMissing,
           report::Orchestrator::BrokerTimeout,
           report::ReleaseChoice::NoRelease,
           report::DockerCli::Error => e
      warn e.message
      status = 1
    end
    exit status
  end
end
