# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "stringio"
require "tmpdir"
require "rpms_rpc/daily_report"

# rpms-rpc#365: orchestration with injected collaborators (release lookup, runner, docker, clock, writer).
class RpmsRpc::DailyReport::OrchestratorTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  PROV123_ACCESS = "SENTINEL-PROV123-ACCESS-SECRET"
  PROV123_VERIFY = "SENTINEL-PROV123-VERIFY-SECRET"
  SYS123_ACCESS = "SENTINEL-SYS123-ACCESS-SECRET"
  SYS123_VERIFY = "SENTINEL-SYS123-VERIFY-SECRET"
  SECRET_PATTERN = /#{PROV123_ACCESS}|#{PROV123_VERIFY}|#{SYS123_ACCESS}|#{SYS123_VERIFY}/
  LATEST = { tag: "bcer-9.0-20261101-latest-ydb", published_at: "2026-11-01T00:00:00Z", image: "ghcr.io/lakeraven/rpms-ydb:bcer-9.0-20261101-latest-ydb" }

  def passing_minitest
    <<~OUT
      Finished in 0.01s, 100 runs/s, 100 assertions/s.
      1 runs, 1 assertions, 0 failures, 0 errors, 0 skips
    OUT
  end

  def failing_minitest
    <<~OUT
      Finished in 0.01s, 100 runs/s, 100 assertions/s.
      2 runs, 2 assertions, 1 failures, 0 errors, 0 skips

      Failure:
      UnitTest#test_bad:
      expected
    OUT
  end

  class FakeReleases
    def initialize(latest:) = @latest = latest
    def fetch_latest_ydb = @latest
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
      key = @index
      @index += 1
      body = @responses.fetch(key)
      { stdout: body.fetch(:stdout), stderr: body.fetch(:stderr, ""), success: body.fetch(:success, true) }
    end
  end

  class FakeDocker
    attr_reader :runs, :removes, :image_calls

    def initialize(image: nil, container_id: "cid-synthetic")
      @image = image
      @container_id = container_id
      @runs = []
      @removes = []
      @image_calls = []
    end

    def image_publishing_port(host, port)
      @image_calls << [ host, port ]
      @image
    end

    def run!(**kwargs)
      @runs << kwargs
      @container_id
    end

    def remove!(container_id, force: true)
      @removes << [ container_id, force ]
    end
  end

  class FakeBrokerProbe
    def initialize(answers)
      @answers = answers.dup
    end

    def cia_connects?(host, port)
      @answers.shift || false
    end
  end

  class FakeClock
    attr_accessor :times

    def initialize(times) = @times = times.dup
    def now = @times.shift || Time.utc(2026, 10, 30, 12, 0, 0)
  end

  class FakePortPicker
    def initialize(port) = @port = port
    def free_loopback_port = @port
  end

  class FakeWriter
    attr_reader :writes

    def initialize = @writes = []
    def write(path, body) = @writes << [ path, body ]
  end

  class StringIOWriter
    attr_reader :io

    def initialize = @io = StringIO.new
    def write(_path, body) = @io.write(body)
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

  def refute_secrets_in(*texts)
    combined = texts.flatten.join("\n")
    refute_match(SECRET_PATTERN, combined)
  end

  def orchestrator(**overrides)
    env = persona_sign_on_env.merge(overrides.fetch(:env, {}))
    defaults = {
      root: ROOT,
      env: env,
      releases: FakeReleases.new(latest: LATEST),
      runner: FakeRunner.new([
        { stdout: passing_minitest },
        { stdout: passing_minitest },
        { stdout: passing_minitest }
      ]),
      docker: FakeDocker.new(image: "ghcr.io/lakeraven/rpms-ydb:bcer-9.0-20261030-under-ydb"),
      broker_probe: FakeBrokerProbe.new([ true ]),
      clock: FakeClock.new([ Time.utc(2026, 10, 30, 12, 0, 0), Time.utc(2026, 10, 30, 12, 0, 10),
                             Time.utc(2026, 10, 30, 12, 0, 20), Time.utc(2026, 10, 30, 12, 0, 55),
                             Time.utc(2026, 10, 30, 12, 1, 0) ]),
      port_picker: FakePortPicker.new(19_301),
      writer: FakeWriter.new,
      rpms_diffs_dir: overrides.fetch(:rpms_diffs_dir) { Dir.mktmpdir("daily-rpms-diffs") },
      pinned_release: "bcer-9.0-20261012-pinned-ydb",
      rpms_rpc_commit: "deadbeef",
      coverage: { ran: false, headline: nil, reason: "skipped in test" }
    }
    defaults.merge(overrides).then { |h| RpmsRpc::DailyReport::Orchestrator.new(**h) }
  end

  def test_build_env_overrides_docker_image
    build = RpmsRpc::DailyReport.build_under_test(
      env: { "BUILD" => "bcer-9.0-20261030-explicit-ydb" },
      docker: FakeDocker.new(image: "ghcr.io/lakeraven/rpms-ydb:other"),
      broker_host: "127.0.0.1",
      broker_port: 19_300
    )

    assert_equal "bcer-9.0-20261030-explicit-ydb", build
  end

  def test_build_from_docker_when_env_build_is_blank
    docker = FakeDocker.new(image: "ghcr.io/lakeraven/rpms-ydb:bcer-9.0-20269999-docker-ydb")
    build = RpmsRpc::DailyReport.build_under_test(
      env: {},
      docker: docker,
      broker_host: "127.0.0.1",
      broker_port: 19_300
    )

    assert_equal [ [ "127.0.0.1", 19_300 ] ], docker.image_calls
    assert_equal "bcer-9.0-20269999-docker-ydb", build
  end

  def test_unknown_build_is_unknown_not_latest
    build = RpmsRpc::DailyReport.build_under_test(
      env: {},
      docker: FakeDocker.new(image: nil),
      broker_host: "127.0.0.1",
      broker_port: 19_300
    )

    assert_equal "unknown", build
  end

  def test_missing_rpms_diffs_daily_dir_fails_before_running_suites
    Dir.mktmpdir do |diffs|
      runner = FakeRunner.new([])
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner)

      error = assert_raises(RpmsRpc::DailyReport::Orchestrator::OutputDirectoryMissing) { orch.run }

      assert_match(/rpc-coverage\/daily/, error.message)
      assert_empty runner.calls
    end
  end

  def test_runs_test_and_live_for_both_personas_with_expected_env
    Dir.mktmpdir do |diffs|
      daily = File.join(diffs, "rpc-coverage/daily")
      FileUtils.mkdir_p(daily)
      runner = FakeRunner.new([
        { stdout: passing_minitest },
        { stdout: passing_minitest },
        { stdout: passing_minitest }
      ])
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner)

      assert_equal 0, orch.run

      assert_equal 3, runner.calls.size
      unit = runner.calls[0]
      assert_equal %w[rake test], unit[:argv]
      refute unit[:env].key?("PERSONA")
      refute unit[:env].key?("RPMS_ACCESS")
      refute unit[:env].key?("RPMS_VERIFY")

      prov = runner.calls[1]
      assert_equal %w[rake test:live], prov[:argv]
      assert_equal "PROV123", prov[:env]["PERSONA"]
      assert_equal "development", prov[:env]["VISTA_RPC_ENV"]
      assert_equal "127.0.0.1", prov[:env]["BROKER_HOST"]
      assert_equal "19300", prov[:env]["BROKER_PORT"]
      assert_equal PROV123_ACCESS, prov[:env]["RPMS_ACCESS"]
      assert_equal PROV123_VERIFY, prov[:env]["RPMS_VERIFY"]
      refute_equal SYS123_ACCESS, prov[:env]["RPMS_ACCESS"]

      sys = runner.calls[2]
      assert_equal %w[rake test:live], sys[:argv]
      assert_equal "SYS123", sys[:env]["PERSONA"]
      refute sys[:env].key?("VISTA_RPC_ENV")
      assert_equal SYS123_ACCESS, sys[:env]["RPMS_ACCESS"]
      assert_equal SYS123_VERIFY, sys[:env]["RPMS_VERIFY"]
      refute_equal PROV123_ACCESS, sys[:env]["RPMS_ACCESS"]
    end
  end

  def test_missing_prov123_sign_on_env_does_not_run_live_reports_error_and_exit_nonzero
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      writer = FakeWriter.new
      runner = FakeRunner.new([
        { stdout: passing_minitest },
        { stdout: passing_minitest }
      ])
      env = persona_sign_on_env("PROV123_ACCESS" => nil, "PROV123_VERIFY" => nil)
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner, writer: writer, env: env)

      assert_equal 1, orch.run

      assert_equal 2, runner.calls.size
      assert_equal %w[rake test], runner.calls[0][:argv]
      assert_equal "SYS123", runner.calls[1][:env]["PERSONA"]
      assert_equal SYS123_ACCESS, runner.calls[1][:env]["RPMS_ACCESS"]

      report = writer.writes.map(&:last).join("\n")
      assert_match(/missing PROV123_ACCESS\/PROV123_VERIFY/i, report)
      refute_match(/#{PROV123_ACCESS}|#{PROV123_VERIFY}/, report)
      refute_secrets_in(report, runner.calls)
    end
  end

  def test_blank_sys123_sign_on_env_does_not_run_live_reports_error_and_exit_nonzero
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      writer = FakeWriter.new
      runner = FakeRunner.new([
        { stdout: passing_minitest },
        { stdout: passing_minitest }
      ])
      env = persona_sign_on_env("SYS123_ACCESS" => "  ", "SYS123_VERIFY" => "")
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner, writer: writer, env: env)

      assert_equal 1, orch.run

      assert_equal 2, runner.calls.size
      assert_equal "PROV123", runner.calls[1][:env]["PERSONA"]

      report = writer.writes.map(&:last).join("\n")
      assert_match(/missing SYS123_ACCESS\/SYS123_VERIFY/i, report)
      refute_secrets_in(report, runner.calls)
    end
  end

  def test_exit_nonzero_when_any_suite_fails
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new([
        { stdout: passing_minitest },
        { stdout: failing_minitest, success: false },
        { stdout: passing_minitest }
      ])
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner)

      assert_equal 1, orch.run
    end
  end

  def test_secrets_never_appear_in_written_report_or_printed_summary
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      writer = FakeWriter.new
      io_writer = StringIOWriter.new
      runner = FakeRunner.new([
        { stdout: passing_minitest },
        { stdout: passing_minitest },
        { stdout: passing_minitest }
      ])
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner, writer: writer, summary_writer: io_writer)

      orch.run

      refute_secrets_in(
        writer.writes.map(&:last),
        io_writer.io.string,
        runner.calls.map { |c| c[:argv].join(" ") },
        runner.calls.map { |c| c[:env].values }
      )
    end
  end

  def test_fresh_dry_run_prints_plan_without_runner_or_docker_side_effects
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new([])
      docker = FakeDocker.new
      io = StringIO.new
      orch = orchestrator(
        rpms_diffs_dir: diffs,
        runner: runner,
        docker: docker,
        env: persona_sign_on_env("FRESH" => "1", "DRY_RUN" => "1"),
        plan_io: io
      )

      assert_equal 0, orch.run

      plan = io.string
      assert_match(/127\.0\.0\.1:19301/, plan)
      assert_match(/bcer-9\.0-20261101-latest-ydb/, plan)
      assert_empty runner.calls
      assert_empty docker.runs
      assert_empty docker.removes
      refute_secrets_in(plan)
    end
  end

  def test_fresh_container_is_removed_after_success_and_after_suite_failure
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      docker = FakeDocker.new
      env = persona_sign_on_env("FRESH" => "1")

      runner_ok = FakeRunner.new([
        { stdout: passing_minitest },
        { stdout: passing_minitest },
        { stdout: passing_minitest }
      ])
      orchestrator(rpms_diffs_dir: diffs, runner: runner_ok, docker: docker, env: env, broker_probe: FakeBrokerProbe.new([ true ])).run
      assert_equal [ [ "cid-synthetic", true ] ], docker.removes

      docker2 = FakeDocker.new
      runner_fail = FakeRunner.new([
        { stdout: failing_minitest, success: false },
        { stdout: passing_minitest },
        { stdout: passing_minitest }
      ])
      orchestrator(rpms_diffs_dir: diffs, runner: runner_fail, docker: docker2, env: env,
                   broker_probe: FakeBrokerProbe.new([ true ])).run
      assert_equal [ [ "cid-synthetic", true ] ], docker2.removes
    end
  end

  def test_fresh_broker_probe_timeout_raises_and_still_removes_container
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      docker = FakeDocker.new
      env = persona_sign_on_env("FRESH" => "1")
      orch = orchestrator(
        rpms_diffs_dir: diffs,
        runner: FakeRunner.new([]),
        docker: docker,
        env: env,
        broker_probe: FakeBrokerProbe.new([ false, false, false ])
      )

      error = assert_raises(RpmsRpc::DailyReport::Orchestrator::BrokerTimeout) { orch.run }

      assert_match(/CIA|broker|timeout/i, error.message)
      assert_equal [ [ "cid-synthetic", true ] ], docker.removes
    end
  end

  def test_exit_nonzero_when_minitest_output_cannot_be_parsed
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new([
        { stdout: "bundler exploded before minitest\n" },
        { stdout: passing_minitest },
        { stdout: passing_minitest }
      ])
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner)

      assert_equal 1, orch.run
    end
  end
end
