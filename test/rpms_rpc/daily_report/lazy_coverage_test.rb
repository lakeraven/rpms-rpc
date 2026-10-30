# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "stringio"
require "tmpdir"
require "rpms_rpc/daily_report"

# rpms-rpc#365 panel round 1: coverage runs lazily after output-dir check, never in DRY_RUN.
class RpmsRpc::DailyReport::LazyCoverageTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  LATEST = { tag: "bcer-9.0-20261101-latest-ydb", published_at: "2026-11-01T00:00:00Z",
             image: "ghcr.io/lakeraven/rpms-ydb:bcer-9.0-20261101-latest-ydb" }

  class CountingCoverage
    attr_reader :calls

    def initialize(result = { ran: false, headline: nil, reason: "not invoked" })
      @result = result
      @calls = 0
    end

    def call
      @calls += 1
      @result
    end

    def [](key) = @result[key]

    def fetch(key, *args) = @result.fetch(key, *args)
  end

  class FakeReleases
    def fetch_latest_ydb = RpmsRpc::DailyReport::LazyCoverageTest::LATEST
  end

  class FakeRunner
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
      @index = 0
    end

    def run(argv, env:, chdir:)
      @calls << { argv: argv.dup, env: env.transform_keys(&:to_s), chdir: chdir }
      body = @responses.fetch(@index)
      @index += 1
      { stdout: body.fetch(:stdout), stderr: body.fetch(:stderr, ""), success: body.fetch(:success, true) }
    end
  end

  class FakeDocker
    attr_reader :runs, :removes

    def initialize
      @runs = []
      @removes = []
    end

    def image_publishing_port(_host, _port) = "ghcr.io/lakeraven/rpms-ydb:bcer-9.0-20261101-latest-ydb"
    def run!(**kwargs) = (@runs << kwargs) && "cid"
    def remove!(_container_id, force: true) = @removes << force
  end

  class FakeBrokerProbe
    def cia_connects?(_host, _port) = true
  end

  class FakeClock
    def now = Time.utc(2026, 10, 30, 12, 0, 0)
  end

  class FakePortPicker
    def free_loopback_port = 19_301
  end

  class FakeWriter
    def write(_path, _body) = nil
  end

  class CountingCommit
    attr_reader :calls

    def initialize(value = "deadbeef")
      @value = value
      @calls = 0
    end

    def call
      @calls += 1
      @value
    end
  end

  PROV123_ACCESS = "LAZY-COV-PROV123-ACCESS"
  PROV123_VERIFY = "LAZY-COV-PROV123-VERIFY"
  SYS123_ACCESS = "LAZY-COV-SYS123-ACCESS"
  SYS123_VERIFY = "LAZY-COV-SYS123-VERIFY"

  def passing_minitest
    <<~OUT
      Finished in 0.01s, 100 runs/s, 100 assertions/s.
      1 runs, 1 assertions, 0 failures, 0 errors, 0 skips
    OUT
  end

  def persona_sign_on_env(overrides = {})
    {
      "BROKER_HOST" => "127.0.0.1",
      "BROKER_PORT" => "19300",
      "PROV123_ACCESS" => PROV123_ACCESS,
      "PROV123_VERIFY" => PROV123_VERIFY,
      "SYS123_ACCESS" => SYS123_ACCESS,
      "SYS123_VERIFY" => SYS123_VERIFY
    }.merge(overrides)
  end

  def orchestrator(**overrides)
    defaults = {
      root: ROOT,
      env: persona_sign_on_env(overrides.dig(:env) || {}),
      releases: FakeReleases.new,
      runner: FakeRunner.new([ { stdout: passing_minitest } ] * 3),
      docker: FakeDocker.new,
      broker_probe: FakeBrokerProbe.new,
      clock: FakeClock.new,
      port_picker: FakePortPicker.new,
      writer: FakeWriter.new,
      rpms_diffs_dir: overrides.fetch(:rpms_diffs_dir) { Dir.mktmpdir("daily-rpms-diffs") },
      pinned_release: "bcer-9.0-20261012-pinned-ydb",
      rpms_rpc_commit: "deadbeef",
      coverage: CountingCoverage.new
    }
    RpmsRpc::DailyReport::Orchestrator.new(**defaults.merge(overrides))
  end

  def test_missing_daily_dir_does_not_invoke_coverage_callable
    coverage = CountingCoverage.new
    Dir.mktmpdir do |diffs|
      orch = orchestrator(rpms_diffs_dir: diffs, coverage: coverage)

      assert_raises(RpmsRpc::DailyReport::Orchestrator::OutputDirectoryMissing) { orch.run }

      assert_equal 0, coverage.calls
    end
  end

  def test_fresh_dry_run_invokes_neither_runner_nor_coverage_callable
    coverage = CountingCoverage.new
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new([])
      docker = FakeDocker.new
      io = StringIO.new
      env = persona_sign_on_env("FRESH" => "1", "DRY_RUN" => "1")
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner, docker: docker, coverage: coverage, env: env,
                          plan_io: io)

      assert_equal 0, orch.run

      assert_empty runner.calls
      assert_equal 0, coverage.calls
    end
  end

  def test_successful_run_invokes_coverage_callable_once_after_suites
    coverage = CountingCoverage.new(ran: true, headline: "RPC coverage: 1.0%", reason: nil)
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new([
        { stdout: passing_minitest },
        { stdout: passing_minitest },
        { stdout: passing_minitest }
      ])
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner, coverage: coverage)

      assert_equal 0, orch.run

      assert_equal 1, coverage.calls
    end
  end

  def test_from_env_wires_lazy_coverage_not_eager_headline
    coverage = CountingCoverage.new
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      env = persona_sign_on_env(
        "FRESH" => "1",
        "DRY_RUN" => "1",
        "RPMS_DIFFS_DIR" => diffs
      )
      commit = CountingCommit.new
      runner = FakeRunner.new([])
      orch = RpmsRpc::DailyReport::Orchestrator.from_env(
        root: ROOT,
        env: env,
        releases: FakeReleases.new,
        runner: runner,
        coverage: coverage,
        rpms_rpc_commit: commit
      )

      assert_equal 0, orch.run
      assert_equal 0, coverage.calls
      assert_equal 0, commit.calls, "DRY_RUN must not invoke the git commit lookup"
      assert_empty runner.calls
    end
  end
end
