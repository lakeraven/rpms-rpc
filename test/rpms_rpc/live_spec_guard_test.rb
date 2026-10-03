# frozen_string_literal: true

require "minitest/autorun"
require "open3"
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

  # -- failure over silent skipping -------------------------------------------

  class Probe < LiveSpec::Test
    def test_reaches_the_broker = assert(client)
  end

  class Tracked < LiveSpec::Test
    def setup = nil # no broker needed to exercise skip_tracked
    def teardown = nil
    def test_tracked = skip_tracked("#310", "the RPC is on no built image")
    def test_untracked = skip_tracked("soon", "no issue")
  end
  # Specimens, run by hand below; never by the runner itself.
  Minitest::Runnable.runnables.delete(Probe)
  Minitest::Runnable.runnables.delete(Tracked)

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
    summary = summarize(env: FULL.merge("LIVE_RUN" => "1"))

    refute summary[:reporter].passed?
    assert_match(/no live spec ran/, summary[:io].string)
  end

  def test_the_summary_ignores_results_that_are_not_live_specs
    summary = summarize(Minitest::Result.from(self), env: FULL)

    assert summary[:reporter].passed?
    assert_empty summary[:io].string, "a plain test run (rake test) prints no live summary"
  end

  private

  def summarize(*results, env:)
    io = StringIO.new
    reporter = LiveSpec::Summary.new(io, env: env)
    reporter.start
    results.each { |r| reporter.record(r) }
    reporter.report
    { io: io, reporter: reporter }
  end

  def with_env(env)
    saved = ENV.to_h.slice(*env.keys)
    env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    env.each_key { |k| saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k) }
  end
end
