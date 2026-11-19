# frozen_string_literal: true

# Daily picture of the gem against a broker (rpms-rpc#365).
#
#   rake report:daily
#   FRESH=1 DRY_RUN=1 rake report:daily
#   FRESH=1 rake report:daily
#
# Existing broker: BROKER_HOST, BROKER_PORT, and optional BUILD.
# LIVE_DISPOSABLE is passed to live children only when set to 1.
# BROKER_PROTOCOL, when set, is passed to those live children only.
# Fresh container: FRESH=1, optional DRY_RUN=1. The image is the newest
# published bcer-*-ydb release of lakeraven/openrpms. Each
# run names its container with the time and a random hex token and removes
# only that name, including after an interrupt. Live children get
# LIVE_DISPOSABLE=1. The report's build is that release's tag, including a
# digest-pinned image; a different BUILD= is an error on a real run and on
# a dry run. A dry run that still cannot resolve a release writes the error
# and exits non-zero. An unknown build exits non-zero.
# Sign-on: <PERSONA>_ACCESS and <PERSONA>_VERIFY for each live persona
# (PROV123, PMD123, PREG123, PSCH123, SYS123; README, Live personas).
# Each pair is handed only to that persona's rake test:live child.
# Output: <rpms-diffs>/rpc-coverage/daily/<date>-<build>.md
# (RPMS_DIFFS_DIR selects the checkout). Each suite's output, redacted like
# the report, is kept beside it as <date>-<build>.<suite id>.log and linked
# from the suite's row (#757). The task exits with the report status.
namespace :report do
  desc "Run rake test and rake test:live once per live persona, and write rpc-coverage/daily/<date>-<build>.md"
  task :daily do
    require "rpms_rpc/daily_report"

    report = RpmsRpc::DailyReport
    root = File.expand_path("../..", __dir__)
    orchestrator = report::Orchestrator.from_env(root: root, env: ENV.to_h)
    begin
      status = orchestrator.run
    rescue report::Orchestrator::OutputDirectoryMissing,
           report::Orchestrator::BrokerTimeout,
           report::Orchestrator::BuildMismatch,
           report::ReleaseChoice::NoRelease,
           report::DockerCli::Error => e
      warn e.message
      status = 1
    end
    exit status
  end
end
