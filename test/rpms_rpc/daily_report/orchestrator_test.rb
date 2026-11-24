# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "stringio"
require "tmpdir"
require "rpms_rpc/daily_report"

# rpms-rpc#365: orchestration with injected collaborators (release lookup, runner, docker, clock, writer).
class RpmsRpc::DailyReport::OrchestratorTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  ROLES = RpmsRpc::DailyReport::LIVE_ROLES
  SIGN_ON = ROLES.to_h do |p|
    [ p, [ "SENTINEL-#{p}-ACCESS-SECRET", "SENTINEL-#{p}-VERIFY-SECRET" ] ]
  end.freeze
  PROVIDER_ACCESS, PROVIDER_VERIFY = SIGN_ON.fetch("provider")
  OPERATOR_ACCESS, OPERATOR_VERIFY = SIGN_ON.fetch("operator")
  SECRET_PATTERN = Regexp.union(SIGN_ON.values.flatten)
  LATEST = { tag: "bcer-9.0-20261101-latest-ydb", published_at: "2026-11-01T00:00:00Z", image: "ghcr.io/lakeraven/rpms-ydb:bcer-9.0-20261101-latest-ydb" }
  DIGEST_PINNED_LATEST = {
    tag: "bcer-9.0-20990101-abc1234-ydb",
    published_at: "2099-01-01T00:00:00Z",
    image: "ghcr.io/lakeraven/rpms-ydb@sha256:#{'a' * 64}"
  }

  def passing_minitest
    <<~OUT
      Finished in 0.01s, 100 runs/s, 100 assertions/s.
      1 runs, 1 assertions, 0 failures, 0 errors, 0 skips
    OUT
  end

  # One passing summary per suite: rake test, then each live role.
  def passing_runs(count = 1 + ROLES.size)
    Array.new(count) { { stdout: passing_minitest } }
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

  class UnresolvedReleases
    def fetch_latest_ydb
      raise RpmsRpc::DailyReport::ReleaseChoice::NoRelease, "no published release matches /\\Abcer-.*-ydb\\z/"
    end
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

  class InterruptRunner
    attr_reader :calls

    def initialize
      @calls = []
    end

    def run(argv, env:, chdir:)
      @calls << { argv: argv.dup, env: env.transform_keys(&:to_s), chdir: chdir }
      raise Interrupt, "simulated operator interrupt during suite"
    end
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
    attr_reader :runs, :removes, :image_calls, :predetermined_name, :name_read_before_run

    def initialize(image: nil, container_id: "cid-synthetic", predetermined_name: "rpms-rpc-daily-report-test",
                   run_error: nil, remove_error: nil)
      @image = image
      @container_id = container_id
      @predetermined_name = predetermined_name
      @run_error = run_error
      @remove_error = remove_error
      @runs = []
      @removes = []
      @image_calls = []
      @name_read_before_run = nil
    end

    def image_publishing_port(host, port)
      @image_calls << [ host, port ]
      @image
    end

    def run!(**kwargs)
      @name_read_before_run = @predetermined_name if @name_read_before_run.nil?
      @runs << kwargs.merge(container_name: @predetermined_name)
      raise RpmsRpc::DailyReport::DockerCli::Error, "docker run failed after container was created" if @run_error

      @predetermined_name
    end

    def remove!(container_id, force: true)
      @removes << [ container_id, force ]
      raise RpmsRpc::DailyReport::DockerCli::Error, "docker rm failed" if @remove_error
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
    def free_loopback_ports(count) = Array.new(count) { |i| @port + i }
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

  def role_sign_on_env(overrides = {})
    {
      "BROKER_HOST" => "127.0.0.1",
      "BROKER_PORT" => "19300"
    }.merge(SIGN_ON.each_with_object({}) { |(p, (access, verify)), acc| acc["#{p.upcase}_ACCESS"] = access; acc["#{p.upcase}_VERIFY"] = verify })
     .merge(overrides)
  end

  def refute_secrets_in(*texts)
    combined = texts.flatten.join("\n")
    refute_match(SECRET_PATTERN, combined)
  end

  def orchestrator(**overrides)
    env = role_sign_on_env.merge(overrides.fetch(:env, {}))
    defaults = {
      root: ROOT,
      env: env,
      releases: FakeReleases.new(latest: LATEST),
      runner: FakeRunner.new(passing_runs),
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
    merged = defaults.merge(overrides)
    merged.delete(:error_io)
    RpmsRpc::DailyReport::Orchestrator.new(**merged)
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

  def test_runs_test_and_live_once_per_live_role_with_its_own_pair
    Dir.mktmpdir do |diffs|
      daily = File.join(diffs, "rpc-coverage/daily")
      FileUtils.mkdir_p(daily)
      runner = FakeRunner.new(passing_runs)
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner)

      assert_equal 0, orch.run

      assert_equal 1 + ROLES.size, runner.calls.size
      assert_equal ROLES, runner.calls.drop(1).map { |call| call[:env]["ROLE"] }
      runner.calls.drop(1).each do |call|
        role = call[:env]["ROLE"]
        assert_equal %w[rake test:live], call[:argv]
        assert_equal SIGN_ON.fetch(role), [ call[:env]["RPMS_ACCESS"], call[:env]["RPMS_VERIFY"] ], role
        refute call[:env].key?("PERSONA"), role
        refute call[:env].key?("VISTA_RPC_ENV"), "no role signs on with a development-only pair: #{role}"
      end
      unit = runner.calls[0]
      assert_equal %w[rake test], unit[:argv]
      refute unit[:env].key?("ROLE")
      refute unit[:env].key?("RPMS_ACCESS")
      refute unit[:env].key?("RPMS_VERIFY")
      refute unit[:env].key?("LIVE_DISPOSABLE")
      refute unit[:env].key?("PROVIDER_ACCESS")
      refute unit[:env].key?("OPERATOR_ACCESS")

      provider = runner.calls[1]
      assert_equal "provider", provider[:env]["ROLE"]
      assert_equal "127.0.0.1", provider[:env]["BROKER_HOST"]
      assert_equal "19300", provider[:env]["BROKER_PORT"]
      assert_equal PROVIDER_ACCESS, provider[:env]["RPMS_ACCESS"]
      assert_equal PROVIDER_VERIFY, provider[:env]["RPMS_VERIFY"]

      operator = runner.calls.last
      assert_equal "operator", operator[:env]["ROLE"]
      assert_equal OPERATOR_ACCESS, operator[:env]["RPMS_ACCESS"]
      assert_equal OPERATOR_VERIFY, operator[:env]["RPMS_VERIFY"]
    end
  end

  # rpms-rpc#848: a role's signature code reaches only its own live child,
  # as RPMS_ESIG, and is scrubbed from the report and every log like a verify code.
  def test_a_roles_signature_code_reaches_only_its_own_live_child_and_is_scrubbed
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      writer = FakeWriter.new
      esig = "SENTINEL-PROVIDER-ESIG-SECRET"
      echoed = "#{failing_minitest}provider signed with #{esig}\n"
      responses = passing_runs.dup
      responses[1 + ROLES.index("provider")] = { stdout: echoed, stderr: "stderr #{esig}" }
      runner = FakeRunner.new(responses)
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner, writer: writer, env: role_sign_on_env("PROVIDER_ESIG" => esig))

      assert_equal 1, orch.run

      by_role = runner.calls.drop(1).to_h { |call| [ call[:env]["ROLE"], call[:env] ] }
      assert_equal esig, by_role.fetch("provider")["RPMS_ESIG"]
      (ROLES - [ "provider" ]).each { |role| refute by_role.fetch(role).key?("RPMS_ESIG"), role }
      unit = runner.calls[0][:env]
      refute unit.key?("RPMS_ESIG")
      refute unit.key?("PROVIDER_ESIG")
      refute by_role.fetch("provider").key?("PROVIDER_ESIG"), "only RPMS_ESIG is handed over"

      written = writer.writes.map(&:last).join("\n")
      assert_match(/provider signed with \[redacted\]/, written, "the provider's log is kept, with the code scrubbed")
      refute_includes written, esig
      refute_includes runner.calls.inspect, esig
      refute_includes by_role.fetch("provider").values.join(" "), esig
    end
  end

  def test_a_blank_signature_code_is_not_handed_over_and_the_role_still_runs
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new(passing_runs)
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner, env: role_sign_on_env("PROVIDER_ESIG" => "  "))

      assert_equal 0, orch.run

      provider = runner.calls.drop(1).find { |call| call[:env]["ROLE"] == "provider" }
      refute_nil provider
      refute provider[:env].key?("RPMS_ESIG")
    end
  end

  # A role whose pair the report's env does not name signs on with its row's
  # published pair (RpmsRpc::TestRoles), which is scrubbed like any verify code.
  def test_an_unnamed_pair_is_the_rows_published_pair
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      writer = FakeWriter.new
      runner = FakeRunner.new(passing_runs)
      env = role_sign_on_env("PROVIDER_ACCESS" => nil, "PROVIDER_VERIFY" => " ")
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner, writer: writer, env: env)

      assert_equal 0, orch.run

      provider = runner.calls.drop(1).find { |call| call[:env]["ROLE"] == "provider" }
      assert_equal RpmsRpc::TestRoles.fetch(:provider).pair, [ provider[:env]["RPMS_ACCESS"], provider[:env]["RPMS_VERIFY"] ]
      refute_includes writer.writes.map(&:last).join("\n"), RpmsRpc::TestRoles.fetch(:provider).verify
    end
  end

  # The operator's verify code is the one the table does not publish.
  # The operator's pair is published, the -demo image's development credential
  # (SYS123 / RPMS.000), so a blank OPERATOR_* override falls back to it and
  # the operator's live suite runs like every other role's.
  def test_a_blank_operator_override_falls_back_to_the_published_pair
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      writer = FakeWriter.new
      runner = FakeRunner.new(passing_runs)
      env = role_sign_on_env("OPERATOR_ACCESS" => "  ", "OPERATOR_VERIFY" => "")
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner, writer: writer, env: env)

      assert_equal 0, orch.run

      operator = runner.calls.find { |call| call[:env]["ROLE"] == "operator" }
      assert_equal RpmsRpc::TestRoles.fetch(:operator).pair, [ operator[:env]["RPMS_ACCESS"], operator[:env]["RPMS_VERIFY"] ]
    end
  end

  def test_exit_nonzero_when_any_suite_fails
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new([ { stdout: passing_minitest }, { stdout: failing_minitest, success: false } ] +
                              passing_runs(ROLES.size - 1))
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner)

      assert_equal 1, orch.run
    end
  end

  def test_secrets_never_appear_in_written_report_or_printed_summary
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      writer = FakeWriter.new
      io_writer = StringIOWriter.new
      runner = FakeRunner.new(passing_runs)
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
        env: role_sign_on_env("FRESH" => "1", "DRY_RUN" => "1"),
        plan_io: io
      )

      assert_equal 0, orch.run

      plan = io.string
      assert_match(/127\.0\.0\.1:19301/, plan)
      assert_match(/127\.0\.0\.1:19302:9101/, plan)
      assert_match(/bcer-9\.0-20261101-latest-ydb/, plan)
      ROLES.each { |role| assert_includes plan, "rake test:live ROLE=#{role}" }
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
      env = role_sign_on_env("FRESH" => "1")

      runner_ok = FakeRunner.new(passing_runs)
      orchestrator(rpms_diffs_dir: diffs, runner: runner_ok, docker: docker, env: env, broker_probe: FakeBrokerProbe.new([ true ])).run
      assert_equal [ [ "rpms-rpc-daily-report-test", true ] ], docker.removes

      docker2 = FakeDocker.new
      runner_fail = FakeRunner.new([ { stdout: failing_minitest, success: false } ] + passing_runs(ROLES.size))
      orchestrator(rpms_diffs_dir: diffs, runner: runner_fail, docker: docker2, env: env,
                   broker_probe: FakeBrokerProbe.new([ true ])).run
      assert_equal [ [ "rpms-rpc-daily-report-test", true ] ], docker2.removes
    end
  end

  def test_fresh_broker_probe_timeout_raises_and_still_removes_container
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      docker = FakeDocker.new
      env = role_sign_on_env("FRESH" => "1")
      orch = orchestrator(
        rpms_diffs_dir: diffs,
        runner: FakeRunner.new([]),
        docker: docker,
        env: env,
        broker_probe: FakeBrokerProbe.new([ false, false, false ])
      )

      error = assert_raises(RpmsRpc::DailyReport::Orchestrator::BrokerTimeout) { orch.run }

      assert_match(/CIA|broker|timeout/i, error.message)
      assert_equal [ [ "rpms-rpc-daily-report-test", true ] ], docker.removes
    end
  end

  def test_exit_nonzero_when_minitest_output_cannot_be_parsed
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new([ { stdout: "bundler exploded before minitest\n" } ] + passing_runs(ROLES.size))
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner)

      assert_equal 1, orch.run
    end
  end

  def test_rake_test_child_never_receives_live_disposable_or_role_sign_on_keys
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new(passing_runs)
      env = role_sign_on_env("LIVE_DISPOSABLE" => "1", "BROKER_PROTOCOL" => "xwb")
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner, env: env)

      orch.run

      unit = runner.calls.fetch(0)
      RpmsRpc::DailyReport::SIGN_ON_KEYS.each do |key|
        refute unit[:env].key?(key), "rake test child must not receive #{key}"
      end
      refute unit[:env].key?("LIVE_DISPOSABLE")
      refute unit[:env].key?("BROKER_PROTOCOL")
    end
  end

  def test_fresh_live_children_receive_live_disposable_on_loopback_broker
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new(passing_runs)
      env = role_sign_on_env("FRESH" => "1")
      orchestrator(rpms_diffs_dir: diffs, runner: runner, env: env,
                   broker_probe: FakeBrokerProbe.new([ true ])).run

      runner.calls.drop(1).each do |call|
        assert_equal "1", call[:env]["LIVE_DISPOSABLE"]
        assert_equal "127.0.0.1", call[:env]["BROKER_HOST"]
      end
    end
  end

  # A CIA spec that registers a patient runs its duplicate lookup over BMX (#609), so a fresh container
  # publishes the BMX broker (9101) beside CIA (9100) and every live child is told its port.
  def test_fresh_container_publishes_bmx_and_live_children_receive_its_port
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new(passing_runs)
      docker = FakeDocker.new
      orchestrator(rpms_diffs_dir: diffs, runner: runner, docker: docker, env: role_sign_on_env("FRESH" => "1"),
                   broker_probe: FakeBrokerProbe.new([ true ])).run

      assert_equal [ "127.0.0.1:19301:9100", "127.0.0.1:19302:9101" ], Array(docker.runs.first[:publish])
      runner.calls.drop(1).each do |call|
        assert_equal "19301", call[:env]["BROKER_PORT"]
        assert_equal "19302", call[:env]["BMX_PORT"]
      end
    end
  end

  def test_existing_broker_passes_the_operators_bmx_port_to_live_children
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new(passing_runs)
      orchestrator(rpms_diffs_dir: diffs, runner: runner, env: role_sign_on_env("BMX_PORT" => "19400")).run

      runner.calls.drop(1).each { |call| assert_equal "19400", call[:env]["BMX_PORT"] }
    end
  end

  def test_existing_broker_passes_live_disposable_only_when_operator_set
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new(passing_runs)
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner, env: role_sign_on_env)
      orch.run
      runner.calls.drop(1).each do |call|
        refute call[:env].key?("LIVE_DISPOSABLE")
      end

      runner2 = FakeRunner.new(passing_runs)
      orch2 = orchestrator(rpms_diffs_dir: diffs, runner: runner2,
                           env: role_sign_on_env("LIVE_DISPOSABLE" => "1"))
      orch2.run
      runner2.calls.drop(1).each do |call|
        assert_equal "1", call[:env]["LIVE_DISPOSABLE"]
      end
    end
  end

  def test_broker_protocol_passes_through_to_live_children_when_set
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new(passing_runs)
      env = role_sign_on_env("BROKER_PROTOCOL" => "bmx")
      orchestrator(rpms_diffs_dir: diffs, runner: runner, env: env).run

      refute runner.calls[0][:env].key?("BROKER_PROTOCOL")
      runner.calls.drop(1).each { |call| assert_equal "bmx", call[:env]["BROKER_PROTOCOL"] }
    end
  end

  ZERO_RUNS = <<~OUT
    Finished in 0.01s, 0 runs/s, 0 assertions/s.
    0 runs, 0 assertions, 0 failures, 0 errors, 0 skips
  OUT

  def test_zero_run_minitest_summary_is_errored_and_exit_nonzero
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      writer = FakeWriter.new
      runner = FakeRunner.new([ { stdout: ZERO_RUNS } ] + passing_runs(ROLES.size))
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner, writer: writer)

      assert_equal 1, orch.run

      report = writer.writes.map(&:last).join("\n")
      assert_match(/0 tests ran|zero tests/i, report)
    end
  end

  def test_unknown_build_exits_nonzero_and_report_is_still_written
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      writer = FakeWriter.new
      runner = FakeRunner.new(passing_runs)
      docker = FakeDocker.new(image: nil)
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner, writer: writer, docker: docker)

      assert_equal 1, orch.run

      report = writer.writes.map(&:last).join("\n")
      assert_match(/build tested: unknown/, report)
    end
  end

  def test_fresh_build_env_mismatch_fails_before_any_runner_call
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new([])
      env = role_sign_on_env("FRESH" => "1", "BUILD" => "bcer-9.0-20260999-wrong-ydb")
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner, env: env,
                          broker_probe: FakeBrokerProbe.new([ true ]))

      assert_raises(RpmsRpc::DailyReport::Orchestrator::BuildMismatch) { orch.run }

      assert_empty runner.calls, "BUILD mismatch must abort before suite children run"
    end
  end

  def test_fresh_docker_run_uses_predetermined_container_name
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      docker = FakeDocker.new(predetermined_name: "rpms-rpc-daily-fixed-name")
      env = role_sign_on_env("FRESH" => "1")
      orchestrator(rpms_diffs_dir: diffs, docker: docker, env: env,
                   broker_probe: FakeBrokerProbe.new([ true ])).run

      refute_empty docker.runs
      assert_equal "rpms-rpc-daily-fixed-name", docker.runs.first.fetch(:container_name)
      assert_equal [ [ "rpms-rpc-daily-fixed-name", true ] ], docker.removes
    end
  end

  def test_fresh_run_failure_after_container_created_still_removes_by_name
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      docker = FakeDocker.new(predetermined_name: "rpms-rpc-daily-leak-guard", run_error: true)
      env = role_sign_on_env("FRESH" => "1")
      orch = orchestrator(
        rpms_diffs_dir: diffs,
        runner: FakeRunner.new([]),
        docker: docker,
        env: env,
        broker_probe: FakeBrokerProbe.new([ true ]),
        summary_writer: StringIOWriter.new
      )

      assert_raises(RpmsRpc::DailyReport::DockerCli::Error) { orch.run }

      assert_equal [ [ "rpms-rpc-daily-leak-guard", true ] ], docker.removes
    end
  end

  def test_fresh_container_remove_failure_is_reported_and_exit_nonzero
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      docker = FakeDocker.new(predetermined_name: "rpms-rpc-daily-stuck", remove_error: true)
      summary = StringIOWriter.new
      env = role_sign_on_env("FRESH" => "1")
      orch = orchestrator(
        rpms_diffs_dir: diffs,
        docker: docker,
        env: env,
        broker_probe: FakeBrokerProbe.new([ true ]),
        summary_writer: summary
      )

      status = nil
      begin
        status = orch.run
      rescue RpmsRpc::DailyReport::DockerCli::Error
        status = 1
      end

      assert_equal 1, status
      combined = summary.io.string
      assert_match(/docker rm failed|container removal/i, combined)
    end
  end

  def orchestrator_accepts_error_io?
    @orchestrator_accepts_error_io ||= RpmsRpc::DailyReport::Orchestrator.instance_method(:initialize).parameters
                                                                      .map(&:last).include?(:error_io)
  end

  def new_orchestrator(**kwargs)
    error_io = kwargs.delete(:error_io) || StringIO.new
    kwargs[:error_io] = error_io if orchestrator_accepts_error_io?
    [ RpmsRpc::DailyReport::Orchestrator.new(**kwargs), error_io ]
  end

  def test_fresh_digest_pinned_image_reports_release_tag_as_build_tested
    Dir.mktmpdir do |diffs|
      daily = File.join(diffs, "rpc-coverage/daily")
      FileUtils.mkdir_p(daily)
      writer = FakeWriter.new
      releases = FakeReleases.new(latest: DIGEST_PINNED_LATEST)
      runner = FakeRunner.new(passing_runs)
      env = role_sign_on_env("FRESH" => "1")
      orch = orchestrator(
        rpms_diffs_dir: diffs,
        releases: releases,
        runner: runner,
        writer: writer,
        env: env,
        broker_probe: FakeBrokerProbe.new([ true ])
      )

      assert_equal 0, orch.run

      report_path, report_body = writer.writes.last
      assert_match(/build tested: bcer-9\.0-20990101-abc1234-ydb/, report_body)
      assert_includes report_path, "2026-10-30-bcer-9.0-20990101-abc1234-ydb.md"
    end
  end

  def test_fresh_build_env_matching_release_tag_is_accepted_when_image_is_digest
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new(passing_runs)
      tag = DIGEST_PINNED_LATEST.fetch(:tag)
      env = role_sign_on_env("FRESH" => "1", "BUILD" => tag)
      orch = orchestrator(
        rpms_diffs_dir: diffs,
        releases: FakeReleases.new(latest: DIGEST_PINNED_LATEST),
        runner: runner,
        env: env,
        broker_probe: FakeBrokerProbe.new([ true ])
      )

      assert_equal 0, orch.run
      assert_equal 1 + ROLES.size, runner.calls.size
    end
  end

  def test_fresh_interrupt_still_removes_container_and_reraises
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      name = "rpms-rpc-daily-report-interrupt-token"
      docker = FakeDocker.new(predetermined_name: name)
      env = role_sign_on_env("FRESH" => "1")
      orch = orchestrator(
        rpms_diffs_dir: diffs,
        runner: InterruptRunner.new,
        docker: docker,
        env: env,
        broker_probe: FakeBrokerProbe.new([ true ])
      )

      assert_raises(Interrupt) { orch.run }

      assert_equal [ [ name, true ] ], docker.removes
    end
  end

  def test_fresh_signal_exception_still_removes_container_and_reraises
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      name = "rpms-rpc-daily-report-signal-token"
      docker = FakeDocker.new(predetermined_name: name)
      runner = Class.new do
        def run(_argv, env:, chdir:)
          raise SignalException, "SIGTERM"
        end
      end.new
      env = role_sign_on_env("FRESH" => "1")
      orch = orchestrator(
        rpms_diffs_dir: diffs,
        runner: runner,
        docker: docker,
        env: env,
        broker_probe: FakeBrokerProbe.new([ true ])
      )

      assert_raises(SignalException) { orch.run }

      assert_equal [ [ name, true ] ], docker.removes
    end
  end

  def test_fresh_container_name_is_unique_per_run_via_injected_docker_name
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      docker_a = FakeDocker.new(predetermined_name: "rpms-rpc-daily-report-run-a")
      docker_b = FakeDocker.new(predetermined_name: "rpms-rpc-daily-report-run-b")
      env = role_sign_on_env("FRESH" => "1")
      orchestrator(rpms_diffs_dir: diffs, docker: docker_a, env: env,
                   broker_probe: FakeBrokerProbe.new([ true ])).run
      orchestrator(rpms_diffs_dir: diffs, docker: docker_b, env: env,
                   broker_probe: FakeBrokerProbe.new([ true ])).run

      assert_equal [ [ "rpms-rpc-daily-report-run-a", true ] ], docker_a.removes
      assert_equal [ [ "rpms-rpc-daily-report-run-b", true ] ], docker_b.removes
      refute_includes docker_a.removes.map(&:first), "rpms-rpc-daily-report-run-b"
      refute_includes docker_b.removes.map(&:first), "rpms-rpc-daily-report-run-a"
    end
  end

  def test_fresh_container_name_is_chosen_before_docker_run
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      docker = FakeDocker.new(predetermined_name: "rpms-rpc-daily-report-before-run")
      env = role_sign_on_env("FRESH" => "1")
      orchestrator(rpms_diffs_dir: diffs, docker: docker, env: env,
                   broker_probe: FakeBrokerProbe.new([ true ])).run

      refute_empty docker.runs
      assert_equal "rpms-rpc-daily-report-before-run", docker.name_read_before_run
      assert_equal docker.predetermined_name, docker.runs.first.fetch(:container_name)
    end
  end

  def test_fresh_dry_run_unresolved_release_fail_closed_on_error_stream
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new([])
      docker = FakeDocker.new
      plan_io = StringIO.new
      error_io = StringIO.new
      env = role_sign_on_env("FRESH" => "1", "DRY_RUN" => "1")
      kwargs = {
        root: ROOT,
        env: env,
        releases: UnresolvedReleases.new,
        runner: runner,
        docker: docker,
        broker_probe: FakeBrokerProbe.new([ true ]),
        clock: FakeClock.new([ Time.utc(2026, 10, 30, 12, 0, 0) ]),
        port_picker: FakePortPicker.new(19_301),
        writer: FakeWriter.new,
        rpms_diffs_dir: diffs,
        pinned_release: "bcer-9.0-20261012-pinned-ydb",
        rpms_rpc_commit: "deadbeef",
        coverage: { ran: false, headline: nil, reason: "skipped" },
        plan_io: plan_io,
        error_io: error_io
      }
      orch, error_io = new_orchestrator(**kwargs)

      assert_equal 1, orch.run

      assert_empty runner.calls
      assert_empty docker.runs
      assert_empty docker.removes
      refute_match(/no published release/i, plan_io.string)
      assert_match(/no published release/i, error_io.string)
    end
  end

  def test_fresh_dry_run_build_mismatch_fail_closed_on_error_stream
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      runner = FakeRunner.new([])
      docker = FakeDocker.new
      plan_io = StringIO.new
      error_io = StringIO.new
      env = role_sign_on_env("FRESH" => "1", "DRY_RUN" => "1", "BUILD" => "bcer-9.0-20260999-wrong-ydb")
      kwargs = {
        root: ROOT,
        env: env,
        releases: FakeReleases.new(latest: LATEST),
        runner: runner,
        docker: docker,
        broker_probe: FakeBrokerProbe.new([ true ]),
        clock: FakeClock.new([ Time.utc(2026, 10, 30, 12, 0, 0) ]),
        port_picker: FakePortPicker.new(19_301),
        writer: FakeWriter.new,
        rpms_diffs_dir: diffs,
        pinned_release: "bcer-9.0-20261012-pinned-ydb",
        rpms_rpc_commit: "deadbeef",
        coverage: { ran: false, headline: nil, reason: "skipped" },
        plan_io: plan_io,
        error_io: error_io
      }
      orch, error_io = new_orchestrator(**kwargs)

      assert_equal 1, orch.run

      assert_empty runner.calls
      assert_empty docker.runs
      refute_match(/BUILD=.*wrong-ydb/i, plan_io.string)
      assert_match(/BUILD=.*wrong-ydb|does not match/i, error_io.string)
    end
  end

  # With no pair in the env, every role but the operator signs on with its
  # row's published pair; the operator's suite is errored, not skipped.
  # With no overrides at all, every role, the operator included, runs on its row's published pair.
  def test_with_no_overrides_every_role_runs_on_its_published_pair
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      writer = FakeWriter.new
      runner = FakeRunner.new(passing_runs)
      env = { "BROKER_HOST" => "127.0.0.1", "BROKER_PORT" => "19300" }
      orch = orchestrator(rpms_diffs_dir: diffs, runner: runner, writer: writer, env: env)

      assert_equal 0, orch.run

      assert_equal 1 + ROLES.size, runner.calls.size, "rake test and every role run"
      report = writer.writes.map(&:last).join("\n")
      ROLES.each do |role|
        assert_match(/\| rake test:live \(#{role}\) \|/, report, "#{role} has its row")
      end
    end
  end

  def test_fresh_container_remove_failure_reaches_summary_when_no_report_was_written
    Dir.mktmpdir do |diffs|
      FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
      docker = FakeDocker.new(predetermined_name: "rpms-rpc-daily-report-no-report", remove_error: true)
      summary = StringIOWriter.new
      writer = FakeWriter.new
      env = role_sign_on_env("FRESH" => "1")
      orch = orchestrator(
        rpms_diffs_dir: diffs,
        runner: FakeRunner.new([]),
        docker: docker,
        writer: writer,
        env: env,
        broker_probe: FakeBrokerProbe.new([ false, false, false ]),
        summary_writer: summary
      )

      assert_raises(RpmsRpc::DailyReport::Orchestrator::BrokerTimeout) { orch.run }

      assert_empty writer.writes, "broker timeout must abort before a report file is written"
      assert_match(/docker rm failed|container removal/i, summary.io.string)
    end
  end
# Each suite's output is kept beside the report and linked from its row
# (#757). A demo access code is published with its role and is kept, so
# redaction must not reach the link or the file name: both come from the suite's id.
def test_each_suite_links_a_redacted_log_beside_the_report_even_with_the_published_pairs
  Dir.mktmpdir do |diffs|
    FileUtils.mkdir_p(File.join(diffs, "rpc-coverage/daily"))
    writer = FakeWriter.new
    failing_live = "#{failing_minitest}provider PMD123 signed on with PMD123!!\n"
    runner = FakeRunner.new([ { stdout: passing_minitest }, { stdout: failing_live } ] + passing_runs(ROLES.size - 1))
    published = ROLES.each_with_object({}) { |p, acc| acc["#{p.upcase}_ACCESS"] = nil; acc["#{p.upcase}_VERIFY"] = nil }
    orch = orchestrator(rpms_diffs_dir: diffs, runner: runner, writer: writer,
                        env: role_sign_on_env(published.merge("OPERATOR_VERIFY" => "SENTINEL-OPERATOR-VERIFY-SECRET")))

    assert_equal 1, orch.run

    report_path, report = writer.writes.find { |path, _| path.end_with?(".md") }
    links = report.scan(/\[log\]\(([^)]+)\)/).flatten
    assert_equal 1 + ROLES.size, links.size, "one log link per suite that ran: #{report}"
    ROLES.each do |role|
      assert_match(/^\| rake test:live \(#{role}\) \|/, report, "#{role} has its row")
      verify = RpmsRpc::TestRoles.fetch(role).verify
      refute_includes report, verify if verify
    end
    assert_includes writer.writes.map(&:last).join, "provider PMD123 signed on with [redacted]",
                    "a published access code is kept; its verify code is scrubbed"
    written = writer.writes.to_h
    links.each do |link|
      assert_equal File.basename(link), link, "the link is a sibling file name"
      assert written.key?(File.join(File.dirname(report_path), link)), "#{link} was written beside the report"
    end
    assert_equal links.uniq, links, "each suite has its own log"
    provider_log = written.fetch(File.join(File.dirname(report_path), links[1]))
    assert_match(/UnitTest#test_bad:\nexpected/, provider_log, "the log holds the failure's message")
    refute_match(/PMD123!!/, provider_log, "the log is redacted like the report")
  end
end
end
