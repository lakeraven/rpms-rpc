# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "securerandom"
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
           "RPMS_VERIFY" => "v", "ROLE" => "provider",
           # The release cache: the committed fixture, whose current.json names a bcer-9.0 -ydb release.
           "OPENRPMS_INVENTORIES" => File.expand_path("../fixtures/inventories", __dir__) }.freeze

  def test_names_every_unset_or_blank_variable
    assert_equal LiveSpec::REQUIRED_ENV, LiveSpec.missing_env({})
    assert_empty LiveSpec.missing_env(FULL)
  end

  # A role signs on with its row's published pair unless the env names
  # another.
  def test_the_pair_is_the_rows_unless_the_env_names_one
    bare = FULL.merge("RPMS_ACCESS" => nil, "RPMS_VERIFY" => " ")
    assert_equal RpmsRpc::TestRoles.fetch(:provider).pair, LiveSpec.sign_on_pair(bare)
    assert_empty LiveSpec.missing_env(bare)
    assert_equal %w[a v], LiveSpec.sign_on_pair(FULL)
    assert_empty LiveSpec.missing_env(bare.merge("ROLE" => "operator"))
    assert_equal %w[SYS123 RPMS.000], LiveSpec.sign_on_pair(bare.merge("ROLE" => "operator"))
    assert_equal [ "SYS123", "v" ], LiveSpec.sign_on_pair(bare.merge("ROLE" => "operator", "RPMS_VERIFY" => "v"))
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
    assert_nil LiveSpec.protocol_error("BROKER_PROTOCOL" => "bmx")
    assert_match(/not one of cia, xwb, bmx/, LiveSpec.protocol_error("BROKER_PROTOCOL" => "rcis"))
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
    runs_as :provider
    def test_reaches_the_broker = assert(client)
  end

  class UndeclaredProbe < LiveSpec::Test
    def test_reaches_the_broker = assert(client)
  end

  class SchedulingProbe < LiveSpec::Test
    runs_as :scheduler
    def test_reaches_the_broker = assert(client)
  end

  class Tracked < LiveSpec::Test
    def setup = nil # no broker needed to exercise skip_tracked
    def teardown = nil
    def test_tracked = skip_tracked("#310", "the RPC is on no built image")
    def test_tracked_elsewhere = skip_tracked("openrpms#1275", "the role is not given the option yet")
    def test_untracked = skip_tracked("soon", "no issue")
    def test_bare = skip("no data")
  end
  class XwbProbe < LiveSpec::Test
    broker :xwb
    runs_as :provider
    def test_reaches_the_broker = assert(client)
  end

  # A spec whose RPCs run under an option the provider's row does not hold.
  class NeedsProbe < LiveSpec::Test
    runs_as :provider, :operator
    needs "AMHGRPC", tracked: "openrpms#1275"
    def test_reaches_the_broker = assert(client)
  end

  # A spec whose role's account no release carries yet (a pending row).
  class PendingProbe < LiveSpec::Test
    runs_as :care_manager
    needs "BQIRPC", tracked: "openrpms#1401"
    def test_reaches_the_broker = assert(client)
  end

  # The harness's sign-on and its XUPROGMODE probe, without a broker: the
  # probe answers what HELD says the account holds.
  class GuardProbe < LiveSpec::Test
    runs_as :provider, :operator
    HELD = {} # role => what the account's XUPROGMODE probe answers
    def test_signs_on = assert(client)

    private

    def sign_on = Struct.new(:disconnect).new
    def xuprogmode_held = HELD.fetch(role)
  end

  class PassingProbe < LiveSpec::Test
    def setup = nil
    def teardown = nil
    def test_passes = assert(true)
  end

  # A spec that proves a scenario and sends one call, recorded as the harness records it.
  class ProvingProbe < LiveSpec::Test
    runs_as :provider
    proves "S-CHT-01.1"
    def setup = LiveSpec::CallLog.start
    def teardown = LiveSpec.calls["#{self.class}##{name}"] = LiveSpec::CallLog.stop
    def test_opens_a_chart = LiveSpec::CallLog.around("ORWPT SELECT") { "5\x00ok" }
  end
  Minitest::Runnable.runnables.delete(ProvingProbe)
  # Specimens, run by hand below; never by the runner itself.
  Minitest::Runnable.runnables.delete(Probe)
  Minitest::Runnable.runnables.delete(XwbProbe)
  Minitest::Runnable.runnables.delete(Tracked)
  Minitest::Runnable.runnables.delete(PassingProbe)
  Minitest::Runnable.runnables.delete(UndeclaredProbe)
  Minitest::Runnable.runnables.delete(SchedulingProbe)
  Minitest::Runnable.runnables.delete(NeedsProbe)
  Minitest::Runnable.runnables.delete(PendingProbe)
  Minitest::Runnable.runnables.delete(GuardProbe)

  # -- test roles: each spec runs as the role whose work it proves (#452) -----

  def test_a_spec_that_declares_no_role_fails_and_says_how_to_declare_one
    result = with_env(FULL) { UndeclaredProbe.new(:test_reaches_the_broker).run }

    refute result.skipped?
    assert_match(/declares no role: add runs_as :<role>/, result.failure.message)
  end

  def test_a_spec_run_by_hand_as_another_role_fails_naming_its_role
    result = with_env(FULL) { SchedulingProbe.new(:test_reaches_the_broker).run }

    refute result.skipped?
    assert_match(/runs as scheduler, and this run signs on as provider: run it with ROLE=scheduler/, result.failure.message)
  end

  def test_a_run_runs_only_the_specs_of_the_role_it_signs_on_as
    assert_empty(with_env("ROLE" => "provider") { SchedulingProbe.runnable_methods })
    assert_equal [ "test_reaches_the_broker" ], with_env("ROLE" => "scheduler") { SchedulingProbe.runnable_methods }
    assert_equal [ "test_reaches_the_broker" ], with_env("ROLE" => "provider") { UndeclaredProbe.runnable_methods },
                 "an undeclared spec still runs, so its setup can say what is missing"
  end

  def test_a_role_the_table_does_not_know_is_refused
    assert_nil LiveSpec.role_error("ROLE" => "front_desk_clerk")
    assert_match(/ROLE="bob" is not a test role: one of provider, nurse, medical_assistant, front_desk_clerk, /,
                 LiveSpec.role_error("ROLE" => "bob"))
  end

  # The old PERSONA names stop working, and the message names the role to set.
  def test_a_retired_persona_fails_naming_the_role_to_set
    assert_match(/PERSONA=PROV123 is retired: .* set ROLE=provider/, LiveSpec.role_error("PERSONA" => "PROV123"))
    assert_match(/PERSONA=PREG123 is retired: .* set ROLE=front_desk_clerk/,
                 LiveSpec.role_error("PERSONA" => "PREG123", "ROLE" => "front_desk_clerk"))
    assert_match(/PERSONA=least_privilege is retired: .* set ROLE to one of provider/,
                 LiveSpec.role_error("PERSONA" => "least_privilege"))

    result = with_env(FULL.merge("PERSONA" => "SYS123")) { Probe.new(:test_reaches_the_broker).run }
    refute result.skipped?
    assert_match(/PERSONA=SYS123 is retired: .* set ROLE=operator/, result.failure.message)
  end

  # Every class of every live spec, on every broker line, declares the
  # roles it runs as, and each is one the table knows.
  def test_every_live_spec_declares_the_roles_it_runs_as
    root = File.expand_path("../..", __dir__)
    files = LiveSpec::SPEC_GLOBS.values.flat_map { |glob| Dir[File.join(root, glob)] }
    refute_empty files
    files.each do |file|
      text = File.read(file)
      classes = text.scan(/< LiveSpec::Test\b/).size
      declared = text.scan(/^\s*runs_as\s/).size
      assert_equal classes, declared, "#{file.delete_prefix("#{root}/")}: #{classes} spec classes, #{declared} runs_as lines"
      unknown = LiveSpec.declared_roles(file) - LiveSpec::ROLES.names
      assert_empty unknown, "#{file.delete_prefix("#{root}/")} runs as roles the table does not know"
    end
  end

  def test_the_plan_lists_each_spec_under_the_roles_it_declares
    plan = LiveSpec.role_plan("cia")

    assert_equal LiveSpec::ROLES.names, plan.keys
    assert_includes plan.fetch(:front_desk_clerk), "test/live/registration_duplicate_live_test.rb"
    refute_includes plan.fetch(:provider), "test/live/registration_duplicate_live_test.rb"
  end

  # CI's live matrix (.github/workflows/openrpms-release.yml) runs every role
  # a spec declares, so no role's specs go unrun.
  def test_ci_runs_every_role_a_spec_declares
    root = File.expand_path("../..", __dir__)
    workflow = File.read(File.join(root, ".github/workflows/openrpms-release.yml"))
    matrix = workflow[/^\s+role: \[([^\]]*)\]/, 1].to_s.split(",").map { |r| r.strip.to_sym }

    assert_equal LiveSpec.roles_in_use, matrix
  end

  # -- the row's one guard: XUPROGMODE ----------------------------------------

  def test_an_account_whose_xuprogmode_disagrees_with_its_row_fails_every_spec
    LiveSpec.forget_xuprogmode_verdicts!
    GuardProbe::HELD.replace(provider: [ "XUPROGMODE" ], operator: [])

    provider = with_env(FULL) { GuardProbe.new(:test_signs_on).run }
    refute provider.passed?
    assert_match(/signed on as provider holds XUPROGMODE, which its row does not give it/, provider.failure.message)

    operator = with_env(FULL.merge("ROLE" => "operator")) { GuardProbe.new(:test_signs_on).run }
    refute operator.passed?
    assert_match(/signed on as operator does not hold XUPROGMODE, which its row says it holds/, operator.failure.message)
  ensure
    LiveSpec.forget_xuprogmode_verdicts!
  end

  def test_an_account_whose_xuprogmode_agrees_with_its_row_runs
    LiveSpec.forget_xuprogmode_verdicts!
    GuardProbe::HELD.replace(provider: [], operator: [ "XUPROGMODE" ])

    assert with_env(FULL) { GuardProbe.new(:test_signs_on).run }.passed?
    assert with_env(FULL.merge("ROLE" => "operator")) { GuardProbe.new(:test_signs_on).run }.passed?
  ensure
    LiveSpec.forget_xuprogmode_verdicts!
  end

  def test_an_unanswered_xuprogmode_probe_fails_the_run
    LiveSpec.forget_xuprogmode_verdicts!
    GuardProbe::HELD.replace(provider: nil)

    result = with_env(FULL) { GuardProbe.new(:test_signs_on).run }
    refute result.passed?
    assert_match(/could not ask whether PROFILE,MD holds XUPROGMODE/, result.failure.message)
  ensure
    LiveSpec.forget_xuprogmode_verdicts!
  end

  # -- a spec that needs an option its role's row does not hold yet ------------

  def test_a_spec_needing_an_option_the_row_lacks_skips_by_its_issue_before_sign_on
    result = with_env(FULL) { NeedsProbe.new(:test_reaches_the_broker).run }

    assert result.skipped?, "the provider's row holds no AMHGRPC, so the spec skips (#{result.failure&.message})"
    assert_match(/\Aopenrpms#1275: provider \(PROFILE,MD\) is not given AMHGRPC/, result.failure.message)
  end

  # bcer-9.0-20261124-60d39b6-ydb carries PROFILE,BH (openrpms#1299), so the
  # behavioral health provider's row is no longer pending and holds AMHGRPC.
  def test_the_bh_provider_row_holds_amhgrpc_now_a_release_carries_its_account
    row = RpmsRpc::TestRoles.fetch(:bh_provider)
    assert_nil row.pending
    assert row.holds?("AMHGRPC")
  end

  # No release carries PROFILE,CM yet (openrpms#1401), so the care manager's
  # row is pending: it holds no option on the build, and a spec needing BQIRPC
  # skips by that issue before any sign-on, saying why.
  def test_a_pending_role_holds_nothing_until_a_release_carries_its_account
    row = RpmsRpc::TestRoles.fetch(:care_manager)
    assert_equal [ "PROFILE,CM", "openrpms#1401" ], [ row.account, row.pending ]
    assert_includes row.contexts, "BQIRPC"
    refute row.holds?("BQIRPC"), "no release carries PROFILE,CM, so the build answers it under no option"
    result = with_env(FULL.merge("ROLE" => "care_manager")) { PendingProbe.new(:test_reaches_the_broker).run }

    assert result.skipped?, "the spec skips rather than sign on as an account the build lacks (#{result.failure&.message})"
    assert_match(/\Aopenrpms#1401: no openrpms release carries care_manager's account \(PROFILE,CM\) yet/, result.failure.message)
  end

  def test_a_spec_needing_an_option_the_row_holds_runs
    result = with_env(FULL.merge("ROLE" => "operator")) { NeedsProbe.new(:test_reaches_the_broker).run }

    refute result.skipped?, "the operator is answered under every option, so the spec runs"
    assert_match(/no broker answers at 127\.0\.0\.1:19300/, result.failure.message)
  end

  def test_a_missing_setting_fails_and_names_it
    result = with_env(FULL.merge("BROKER_PORT" => nil, "ROLE" => nil)) { Probe.new(:test_reaches_the_broker).run }

    refute result.skipped?, "a missing setting is a mistake, not an opt-out"
    refute result.passed?
    assert_match(/BROKER_PORT, ROLE/, result.failure.message)
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

    elsewhere = Tracked.new(:test_tracked_elsewhere).run
    assert elsewhere.skipped?, "an issue of another repository is a tracked issue too"
    assert_match(/\Aopenrpms#1275: /, elsewhere.failure.message)
  end

  # Invoking `rake test:live` means you meant to reach RPMS: without the
  # settings it stops before loading a spec, non-zero, naming what is missing.
  def test_rake_test_live_fails_without_its_settings
    env = LiveSpec::REQUIRED_ENV.to_h { |k| [ k, nil ] }
    out, status = Open3.capture2e(env, "bundle", "exec", "rake", "test:live", chdir: File.expand_path("../..", __dir__))

    refute status.success?, "rake test:live passed with no broker settings:\n#{out}"
    assert_match(/settings are missing: BROKER_HOST, BROKER_PORT, ROLE/, out)
    refute_match(/runs, .* assertions/, out, "no spec should load")
  end

  # -- the end-of-run summary --------------------------------------------------

  def test_the_summary_names_backend_build_role_and_counts_and_never_codes
    summary = summarize(Tracked.new(:test_tracked).run, env: FULL.merge("RPMS_ACCESS" => "ACCESS-CODE", "RPMS_VERIFY" => "VERIFY-CODE"))

    out = summary[:io].string
    assert_match(/backend\s+127\.0\.0\.1:19300/, out)
    assert_match(/build\s+bcer-9\.0-\S+-(ydb|iris) \(release under test, not verified/, out)
    assert_match(/role\s+provider/, out)
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
      ok, reasons = RpmsRpc::LiveSummary.check(dir: tmpdir, build: data["build"], source: data["source"],
                                                suite: repo_suite)
      refute ok
      assert_match(/pending/i, reasons.join(" "))
    end
  end

  # rpms-rpc#441: a run whose shipped files changed after the marker was written
  # is not recorded, so the result is never attributed to a source it did not test.
  def test_a_run_whose_source_changed_midway_is_not_recorded
    Dir.mktmpdir do |tmpdir|
      env = FULL.merge("LIVE_RUN" => "1", "LIVE_SUMMARY_DIR" => tmpdir)
      path = mark_pending_in(tmpdir, env: env)
      data = JSON.parse(File.read(path))
      data["source"] = "sha256:#{'0' * 64}" # the tree as it stood when the run began
      File.write(path, "#{JSON.generate(data)}\n")

      io = StringIO.new
      reporter = LiveSpec::Summary.new(io, env: env, expected_runs: 1)
      reporter.start
      reporter.record(PassingProbe.new(:test_passes).run)
      reporter.report

      assert_match(/NOT RECORDED: the shipped source changed during the run/, io.string)
      assert_equal true, JSON.parse(File.read(path))["pending"]
    end
  end

  def test_a_report_without_this_runs_pending_marker_is_not_recorded
    Dir.mktmpdir do |tmpdir|
      root = File.expand_path("../..", __dir__)
      identity = RpmsRpc::LiveSummary.run_identity(FULL, root: root)
      path = RpmsRpc::LiveSummary.path_for(tmpdir, role: identity[:role], protocol: identity[:protocol])
      RpmsRpc::LiveSummary.write(
        path,
        {
          "build" => identity[:build],
          "build_source" => identity[:build_source],
          "protocol" => identity[:protocol],
          "role" => identity[:role],
          "runs" => 7,
          "assertions" => 0,
          "failures" => 1,
          "errors" => 0,
          "skips" => 0
        },
        env: FULL.merge("LIVE_RUN" => "1")
      )

      env = FULL.merge("LIVE_RUN" => "1", "LIVE_SUMMARY_DIR" => tmpdir)
      io = StringIO.new
      reporter = LiveSpec::Summary.new(io, env: env, expected_runs: 1)
      reporter.start
      reporter.record(PassingProbe.new(:test_passes).run)
      reporter.report

      assert_match(/NOT RECORDED/, io.string)
      assert_match(/pending marker/, io.string)
      data = JSON.parse(File.read(path))
      assert_equal 1, data["failures"]
      assert_equal 7, data["runs"]
    end
  end

  def test_a_report_for_another_runs_pending_marker_is_not_recorded
    Dir.mktmpdir do |tmpdir|
      env = FULL.merge("LIVE_RUN" => "1", "LIVE_SUMMARY_DIR" => tmpdir, "LIVE_RUN_ID" => "bbbb")
      path = mark_pending_in(tmpdir, env: env, run_id: "aaaa")

      io = StringIO.new
      reporter = LiveSpec::Summary.new(io, env: env, expected_runs: 1)
      reporter.start
      reporter.record(PassingProbe.new(:test_passes).run)
      reporter.report

      assert_match(/NOT RECORDED/, io.string)
      data = JSON.parse(File.read(path))
      assert_equal true, data["pending"]
      assert_equal "aaaa", data["run_id"]
    end
  end

  def test_a_report_matching_its_pending_marker_is_recorded
    Dir.mktmpdir do |tmpdir|
      run_token = "abcd1234"
      env = FULL.merge("LIVE_RUN" => "1", "LIVE_SUMMARY_DIR" => tmpdir, "LIVE_RUN_ID" => run_token)
      mark_pending_in(tmpdir, env: env, run_id: run_token)

      summary = summarize(PassingProbe.new(:test_passes).run, env: env, expected_runs: 1)

      refute_match(/NOT RECORDED/, summary[:io].string)
      paths = Dir[File.join(tmpdir, "*.json")]
      assert_equal 1, paths.size
      data = JSON.parse(File.read(paths.first))
      refute data["pending"]
      assert_equal 1, data["runs"]
    end
  end

  # rpms-rpc#818: the summary lists each spec run, the scenarios it proves and the calls it sent.
  def test_the_summary_records_each_spec_with_its_scenarios_and_calls
    Dir.mktmpdir do |tmpdir|
      env = FULL.merge("LIVE_RUN" => "1", "LIVE_SUMMARY_DIR" => tmpdir, "LIVE_RUN_ID" => "f00d")
      mark_pending_in(tmpdir, env: env, run_id: "f00d")
      summarize(ProvingProbe.new(:test_opens_a_chart).run, env: env, expected_runs: 1)
      data = JSON.parse(File.read(Dir[File.join(tmpdir, "*.json")].first))
      assert_equal [ { "spec" => "LiveSpecGuardTest::ProvingProbe#test_opens_a_chart", "proves" => [ "S-CHT-01.1" ],
                       "result" => "pass", "calls" => [ { "rpc" => "ORWPT SELECT", "outcome" => "answered" } ] } ], data["specs"]
    end
  end

  # A run whose account's XUPROGMODE disagreed with its role's row proves no scenario: it records no spec.
  def test_a_run_refused_for_its_xuprogmode_records_no_spec
    Dir.mktmpdir do |tmpdir|
      env = FULL.merge("LIVE_RUN" => "1", "LIVE_SUMMARY_DIR" => tmpdir, "LIVE_RUN_ID" => "beef")
      mark_pending_in(tmpdir, env: env, run_id: "beef")
      LiveSpec.forget_xuprogmode_verdicts!
      LiveSpec.xuprogmode_verdict(LiveSpec::ROLES.fetch(:provider)) { [ "XUPROGMODE" ] }
      summarize(ProvingProbe.new(:test_opens_a_chart).run, env: env, expected_runs: 1)
      assert_equal [], JSON.parse(File.read(Dir[File.join(tmpdir, "*.json")].first))["specs"]
    ensure
      LiveSpec.forget_xuprogmode_verdicts!
    end
  end

  def test_proves_takes_scenario_ids_only
    klass = Class.new(LiveSpec::Test)
    assert_equal [], klass.proves
    klass.proves "S-SCH-01.1", "S-SCH-01.1", "S-SCH-01.10"
    assert_equal %w[S-SCH-01.1 S-SCH-01.10], klass.proves
    assert_raises(ArgumentError) { klass.proves "S-SCH-01" }
    assert_raises(ArgumentError) { klass.proves "SCH-01.1" }
  ensure
    Minitest::Runnable.runnables.delete(klass)
  end

  def test_a_complete_live_run_is_recorded
    Dir.mktmpdir do |tmpdir|
      env = FULL.merge("LIVE_RUN" => "1", "LIVE_SUMMARY_DIR" => tmpdir)
      mark_pending_in(tmpdir, env: env)
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

  # Minitest 6 stores --name as options[:include] (5 used :filter), and --exclude
  # as options[:exclude]; either is a filtered run.
  def test_a_run_filtered_by_minitest_6_name_is_not_recorded
    assert_options_filtered_not_recorded(include: "/only/")
  end

  def test_a_run_filtered_by_exclude_is_not_recorded
    assert_options_filtered_not_recorded(exclude: "/skipme/")
  end

  def test_a_run_filtered_by_TESTOPT_is_not_recorded
    assert_filtered_env_not_recorded("TESTOPT" => "--name=x")
  end

  def test_a_run_filtered_by_TEST_OPTS_is_not_recorded
    assert_filtered_env_not_recorded("TEST_OPTS" => "--name=x")
  end

  def test_a_run_filtered_by_TEST_OPT_is_not_recorded
    assert_filtered_env_not_recorded("TEST_OPT" => "--name=x")
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
      env = FULL.merge("LIVE_RUN" => "1", "LIVE_SUMMARY_DIR" => tmpdir)
      mark_pending_in(tmpdir, env: env)
      summarize(env: env, expected_runs: 0)

      paths = Dir[File.join(tmpdir, "*.json")]
      assert_equal 1, paths.size
      data = JSON.parse(File.read(paths.first))
      assert_equal 0, data["runs"]

      ok, reasons = RpmsRpc::LiveSummary.check(dir: tmpdir, build: data["build"], source: data["source"],
                                                suite: repo_suite)
      refute ok
      assert_match(/no live spec ran|pending/i, reasons.join(" "))
    end
  end

  def test_an_unsafe_role_is_reported_not_recorded
    Dir.mktmpdir do |tmpdir|
      summary = summarize(env: FULL.merge("LIVE_RUN" => "1", "ROLE" => "../x", "LIVE_SUMMARY_DIR" => tmpdir))

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

  def repo_root = @repo_root ||= File.expand_path("../..", __dir__)

  def repo_suite = @repo_suite ||= RpmsRpc::LiveSummary.suite_fingerprint(repo_root)

  def assert_options_filtered_not_recorded(options)
    Dir.mktmpdir do |tmpdir|
      env = FULL.merge("LIVE_RUN" => "1", "LIVE_SUMMARY_DIR" => tmpdir)
      path = mark_pending_in(tmpdir, env: env)

      io = StringIO.new
      reporter = LiveSpec::Summary.new(io, env: env, expected_runs: 1, options: options)
      reporter.start
      reporter.record(PassingProbe.new(:test_passes).run)
      reporter.report

      assert_match(/NOT RECORDED/, io.string)
      assert_equal true, JSON.parse(File.read(path))["pending"]
    end
  end

  def assert_filtered_env_not_recorded(filter_env)
    Dir.mktmpdir do |tmpdir|
      env = FULL.merge("LIVE_RUN" => "1", "LIVE_SUMMARY_DIR" => tmpdir).merge(filter_env)
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

  def mark_pending_in(dir, env:, run_id: nil)
    if run_id
      marker_run_id = run_id
    else
      marker_run_id = env["LIVE_RUN_ID"].to_s.strip
      if marker_run_id.empty?
        marker_run_id = SecureRandom.hex(8)
        env["LIVE_RUN_ID"] = marker_run_id
      end
    end

    root = File.expand_path("../..", __dir__)
    identity = RpmsRpc::LiveSummary.run_identity(env, root: root)
    path = RpmsRpc::LiveSummary.path_for(dir, role: identity[:role], protocol: identity[:protocol])
    pending_args = {
      role: identity[:role],
      protocol: identity[:protocol],
      build: identity[:build],
      build_source: identity[:build_source],
      source: identity[:source],
      run_id: marker_run_id,
      env: env
    }
    RpmsRpc::LiveSummary.mark_pending(path, **pending_args)
    path
  end
end
