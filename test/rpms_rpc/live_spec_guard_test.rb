# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "rpms_rpc/live_summary"
require_relative "../live/live_helper"

# The live-spec harness fails closed (ADR 0009): a spec FAILS, never skips,
# without a full broker env or a reachable broker; a spec that writes runs only
# against a target declared disposable on this machine; the one acceptable
# skip names a tracked issue; and the live run ends in a summary that is never
# green when no live spec ran.
class LiveSpecGuardTest < Minitest::Test
  FULL = { "BROKER_HOST" => "127.0.0.1", "BROKER_PORT" => "19300", "RPMS_ACCESS" => "a",
           "RPMS_VERIFY" => "v", "PERSONA" => "PROV123" }.freeze

  def test_names_every_unset_or_blank_variable
    assert_equal LiveSpec::REQUIRED_ENV, LiveSpec.missing_env({})
    assert_equal %w[RPMS_VERIFY], LiveSpec.missing_env(FULL.merge("RPMS_VERIFY" => " "))
    assert_empty LiveSpec.missing_env(FULL)
  end

  def test_a_write_needs_the_target_declared_disposable
    assert_match(/LIVE_DISPOSABLE/, LiveSpec.write_refusal(FULL))
    assert_match(/LIVE_DISPOSABLE/, LiveSpec.write_refusal(FULL.merge("LIVE_DISPOSABLE" => "yes")))
  end

  def test_a_write_needs_a_loopback_host
    env = FULL.merge("LIVE_DISPOSABLE" => "1", "BROKER_HOST" => "10.0.0.5")
    assert_match(/not loopback/, LiveSpec.write_refusal(env))
  end

  def test_a_disposable_local_target_may_be_written
    assert_nil LiveSpec.write_refusal(FULL.merge("LIVE_DISPOSABLE" => "1"))
  end

  # -- one broker line per run -------------------------------------------------

  def test_the_protocol_is_cia_unless_named
    assert_equal "cia", LiveSpec.protocol({})
    assert_equal "xwb", LiveSpec.protocol("BROKER_PROTOCOL" => "XWB")
    assert_nil LiveSpec.protocol_error("BROKER_PROTOCOL" => "xwb")
    assert_match(/not one of cia, xwb/, LiveSpec.protocol_error("BROKER_PROTOCOL" => "bmx"))
  end

  # A mixed suite: each protocol's run loads only the specs written for it.
  def test_each_protocol_loads_only_its_own_specs
    root = File.expand_path("../..", __dir__)
    cia = Dir[File.join(root, LiveSpec::SPEC_GLOBS.fetch("cia"))]
    xwb = Dir[File.join(root, LiveSpec::SPEC_GLOBS.fetch("xwb"))]

    refute_empty cia
    refute_empty xwb
    assert_empty cia & xwb
    assert(xwb.all? { |f| f.include?("/test/live/xwb/") })
  end

  def test_a_spec_run_under_the_other_protocol_fails_and_names_the_setting
    result = with_env(FULL.merge("BROKER_PROTOCOL" => "cia")) { XwbProbe.new(:test_reaches_the_broker).run }

    refute result.skipped?
    assert_match(/written for the xwb broker and this run speaks cia: set BROKER_PROTOCOL=xwb/, result.failure.message)
  end

  def test_the_summary_names_the_protocol_and_a_declared_build
    summary = summarize(Tracked.new(:test_tracked).run,
                        env: FULL.merge("BROKER_PROTOCOL" => "xwb", "LIVE_BUILD" => "some-build"))

    assert_match(/backend\s+127\.0\.0\.1:19300 \(xwb\)/, summary[:io].string)
    assert_match(/build\s+some-build \(declared by LIVE_BUILD, not verified\)/, summary[:io].string)
  end

  # -- failure over silent skipping -------------------------------------------

  class Probe < LiveSpec::Test
    def test_reaches_the_broker = assert(client)
  end

  class Tracked < LiveSpec::Test
    def setup = nil # no broker needed to exercise skip_tracked
    def teardown = nil
    def test_tracked = skip_tracked("#310", "the RPC is on no built image")
    def test_untracked = skip_tracked("soon", "no issue")
    def test_bare = skip("no data")
  end
  class XwbProbe < LiveSpec::Test
    broker :xwb
    def test_reaches_the_broker = assert(client)
  end

  class PassingProbe < LiveSpec::Test
    def setup = nil
    def teardown = nil
    def test_passes = assert(true)
  end
  # Specimens, run by hand below; never by the runner itself.
  Minitest::Runnable.runnables.delete(Probe)
  Minitest::Runnable.runnables.delete(XwbProbe)
  Minitest::Runnable.runnables.delete(Tracked)
  Minitest::Runnable.runnables.delete(PassingProbe)

  def test_a_missing_setting_fails_and_names_it
    result = with_env(FULL.merge("RPMS_VERIFY" => nil, "PERSONA" => nil)) { Probe.new(:test_reaches_the_broker).run }

    refute result.skipped?, "a missing setting is a mistake, not an opt-out"
    refute result.passed?
    assert_match(/RPMS_VERIFY, PERSONA/, result.failure.message)
  end

  def test_an_unreachable_broker_fails_and_says_what_to_do
    result = with_env(FULL.merge("BROKER_PORT" => "1")) { Probe.new(:test_reaches_the_broker).run }

    refute result.skipped?
    assert_match(/no broker answers at 127\.0\.0\.1:1/, result.failure.message)
    assert_match(/container|tunnel/, result.failure.message)
  end

  def test_a_skip_names_a_tracked_issue
    tracked = Tracked.new(:test_tracked).run
    assert tracked.skipped?
    assert_match(/\A#310: /, tracked.failure.message)

    untracked = Tracked.new(:test_untracked).run
    refute untracked.skipped?
    assert_match(/names no issue/, untracked.failure.message)

    bare = Tracked.new(:test_bare).run
    refute bare.skipped?
    assert_match(/bare skip/, bare.failure.message)
  end

  # Invoking `rake test:live` means you meant to reach RPMS: without the
  # settings it stops before loading a spec, non-zero, naming what is missing.
  def test_rake_test_live_fails_without_its_settings
    env = LiveSpec::REQUIRED_ENV.to_h { |k| [ k, nil ] }
    out, status = Open3.capture2e(env, "bundle", "exec", "rake", "test:live", chdir: File.expand_path("../..", __dir__))

    refute status.success?, "rake test:live passed with no broker settings:\n#{out}"
    assert_match(/settings are missing: BROKER_HOST, BROKER_PORT, RPMS_ACCESS, RPMS_VERIFY, PERSONA/, out)
    refute_match(/runs, .* assertions/, out, "no spec should load")
  end

  # -- the end-of-run summary --------------------------------------------------

  def test_the_summary_names_backend_build_persona_and_counts_and_never_codes
    summary = summarize(Tracked.new(:test_tracked).run, env: FULL.merge("RPMS_ACCESS" => "ACCESS-CODE", "RPMS_VERIFY" => "VERIFY-CODE"))

    out = summary[:io].string
    assert_match(/backend\s+127\.0\.0\.1:19300/, out)
    assert_match(/build\s+\S+.*pinned, not verified/, out)
    assert_match(/persona\s+PROV123/, out)
    assert_match(/1 runs, 0 assertions, 0 failures, 0 errors, 1 skips/, out)
    assert_match(/#310\s+1\s/, out)
    refute_match(/ACCESS-CODE|VERIFY-CODE/, out)
  end

  def test_a_live_run_with_no_live_spec_is_not_green
    Dir.mktmpdir do |tmpdir|
      summary = summarize(env: FULL.merge("LIVE_RUN" => "1", "LIVE_SUMMARY_DIR" => tmpdir),
                          expected_runs: 0)

      refute summary[:reporter].passed?
      assert_match(/no live spec ran/, summary[:io].string)
    end
  end

  def test_an_interrupted_live_run_is_not_recorded
    Dir.mktmpdir do |tmpdir|
      env = FULL.merge("LIVE_RUN" => "1", "LIVE_SUMMARY_DIR" => tmpdir)
      path = mark_pending_in(tmpdir, env: env)

      io = StringIO.new
      reporter = LiveSpec::Summary.new(io, env: env, expected_runs: 3)
      reporter.start
      reporter.record(PassingProbe.new(:test_passes).run)
      reporter.report

      assert_match(/NOT RECORDED/, io.string)
      assert_match(/1 of 3|partial|interrupted/, io.string)
      data = JSON.parse(File.read(path))
      assert_equal true, data["pending"]
      ok, reasons = RpmsRpc::LiveSummary.check(dir: tmpdir, build: data["build"])
      refute ok
      assert_match(/pending/i, reasons.join(" "))
    end
  end

  def test_a_complete_live_run_is_recorded
    Dir.mktmpdir do |tmpdir|
      env = FULL.merge("LIVE_RUN" => "1", "LIVE_SUMMARY_DIR" => tmpdir)
      summary = summarize(PassingProbe.new(:test_passes).run, env: env, expected_runs: 1)

      refute_match(/NOT RECORDED/, summary[:io].string)
      paths = Dir[File.join(tmpdir, "*.json")]
      assert_equal 1, paths.size
      data = JSON.parse(File.read(paths.first))
      refute data["pending"]
      assert_equal 1, data["runs"]
    end
  end

  def test_a_run_filtered_by_TEST_is_not_recorded
    Dir.mktmpdir do |tmpdir|
      env = FULL.merge("LIVE_RUN" => "1", "LIVE_SUMMARY_DIR" => tmpdir, "TEST" => "test/live/x_test.rb")
      path = mark_pending_in(tmpdir, env: env)

      io = StringIO.new
      reporter = LiveSpec::Summary.new(io, env: env, expected_runs: 1)
      reporter.start
      reporter.record(PassingProbe.new(:test_passes).run)
      reporter.report

      assert_match(/NOT RECORDED/, io.string)
      assert_match(/filter|TEST/i, io.string)
      assert_equal true, JSON.parse(File.read(path))["pending"]
    end
  end

  def test_a_run_filtered_by_name_is_not_recorded
    base_env = FULL.merge("LIVE_RUN" => "1")

    Dir.mktmpdir do |tmpdir|
      env = base_env.merge("LIVE_SUMMARY_DIR" => tmpdir)
      path = mark_pending_in(tmpdir, env: env)

      io = StringIO.new
      reporter = LiveSpec::Summary.new(io, env: env, expected_runs: 1, options: { filter: "/only/" })
      reporter.start
      reporter.record(PassingProbe.new(:test_passes).run)
      reporter.report

      assert_match(/NOT RECORDED/, io.string)
      assert_match(/filter|TEST/i, io.string)
      assert_equal true, JSON.parse(File.read(path))["pending"]
    end

    Dir.mktmpdir do |tmpdir|
      env = base_env.merge("LIVE_SUMMARY_DIR" => tmpdir, "TESTOPTS" => "--name=x")
      path = mark_pending_in(tmpdir, env: env)

      io = StringIO.new
      reporter = LiveSpec::Summary.new(io, env: env, expected_runs: 1)
      reporter.start
      reporter.record(PassingProbe.new(:test_passes).run)
      reporter.report

      assert_match(/NOT RECORDED/, io.string)
      assert_match(/filter|TEST/i, io.string)
      assert_equal true, JSON.parse(File.read(path))["pending"]
    end
  end

  def test_expected_runs_counts_loaded_live_test_methods
    expected = Minitest::Runnable.runnables
                                  .grep(Class)
                                  .select { |klass| klass < LiveSpec::Test && klass != LiveSpec::Test }
                                  .sum { |klass| klass.runnable_methods.size }

    assert_equal expected, LiveSpec::Summary.new(StringIO.new, env: {}).expected_runs
  end

  def test_a_live_report_writes_only_into_the_summary_dir
    Dir.mktmpdir do |tmpdir|
      summarize(env: FULL.merge("LIVE_RUN" => "1", "LIVE_SUMMARY_DIR" => tmpdir), expected_runs: 0)

      paths = Dir[File.join(tmpdir, "*.json")]
      assert_equal 1, paths.size
      data = JSON.parse(File.read(paths.first))
      assert_equal 0, data["runs"]

      ok, reasons = RpmsRpc::LiveSummary.check(dir: tmpdir, build: data["build"])
      refute ok
      assert_match(/no live spec ran|pending/i, reasons.join(" "))
    end
  end

  def test_an_unsafe_persona_is_reported_not_recorded
    Dir.mktmpdir do |tmpdir|
      summary = summarize(env: FULL.merge("LIVE_RUN" => "1", "PERSONA" => "../x", "LIVE_SUMMARY_DIR" => tmpdir))

      assert_match(/NOT RECORDED/, summary[:io].string)
      assert_empty Dir[File.join(tmpdir, "*.json")]
    end
  end

  def test_the_summary_ignores_results_that_are_not_live_specs
    summary = summarize(Minitest::Result.from(self), env: FULL)

    assert summary[:reporter].passed?
    assert_empty summary[:io].string, "a plain test run (rake test) prints no live summary"
  end

  private

  def summarize(*results, env:, **summary_kwargs)
    env = env.dup
    tmpdir = nil
    if env["LIVE_RUN"] == "1" && env["LIVE_SUMMARY_DIR"].to_s.strip.empty?
      tmpdir = Dir.mktmpdir("live-summary-")
      env["LIVE_SUMMARY_DIR"] = tmpdir
    end
    io = StringIO.new
    reporter = LiveSpec::Summary.new(io, env: env, **summary_kwargs)
    reporter.start
    results.each { |r| reporter.record(r) }
    reporter.report
    { io: io, reporter: reporter, summary_dir: env["LIVE_SUMMARY_DIR"], tmpdir: tmpdir }
  ensure
    FileUtils.rm_rf(tmpdir) if tmpdir
  end

  def with_env(env)
    saved = ENV.to_h.slice(*env.keys)
    env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    env.each_key { |k| saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k) }
  end

  def mark_pending_in(dir, env:)
    root = File.expand_path("../..", __dir__)
    identity = RpmsRpc::LiveSummary.run_identity(env, root: root)
    path = RpmsRpc::LiveSummary.path_for(dir, persona: identity[:persona], protocol: identity[:protocol])
    RpmsRpc::LiveSummary.mark_pending(
      path,
      persona: identity[:persona],
      protocol: identity[:protocol],
      build: identity[:build],
      build_source: identity[:build_source],
      env: env
    )
    path
  end
end
