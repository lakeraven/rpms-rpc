# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../../tools/rpc_coverage/scenarios"
require_relative "../live/live_env"

# rake rpc:coverage's headline (rpms-rpc#818): the pilot scenarios whose calls are all proven live as the role that
# plays them, from the live specs' `proves` lines and the per-role summaries `rake test:live` writes.
class RpcCoverageScenariosTest < Minitest::Test
  S = RpcCoverage::Scenarios
  ROOT = File.expand_path("../..", __dir__)
  PILOT = { "S-SCH-01" => "scheduler", "S-REG-02" => "front_desk_clerk", "S-SGN-01" => "provider" }.freeze

  def plan
    { "test/live/book_live_test.rb" => { roles: [ :scheduler ], scenarios: [ "S-SCH-01.1", "S-SCH-01.2" ] },
      "test/live/register_live_test.rb" => { roles: [ :front_desk_clerk ], scenarios: [ "S-REG-02.1" ] },
      "test/live/coverage_write_live_test.rb" => { roles: [ :operator ], scenarios: [ "S-REG-02.14" ] },
      "test/live/other_live_test.rb" => { roles: [ :provider ], scenarios: [ "S-TRI-04.1" ] } }
  end

  def spec(name, proves, result, calls, skip: nil)
    { "spec" => name, "proves" => proves, "result" => result, "calls" => calls }.tap { |s| s["skip"] = skip if skip }
  end

  def call(rpc, outcome = "answered") = { "rpc" => rpc, "outcome" => outcome }

  def summaries(scheduler: nil, front_desk_clerk: nil, operator: nil)
    { "scheduler" => scheduler, "front_desk_clerk" => front_desk_clerk, "operator" => operator }.compact
      .transform_values { |specs| { "build" => "bcer-test-ydb", "specs" => specs } }
  end

  def report(**kw) = S.report(pilot: PILOT, plan: plan, summaries: summaries(**kw))
  def row(r, id) = r.rows.find { |x| x.id == id } || flunk("no row for #{id}")

  def test_a_scenario_is_proven_when_its_specs_passed_as_its_role_and_sent_calls
    r = report(scheduler: [ spec("Book#test_a", [ "S-SCH-01.1" ], "pass", [ call("BSDX ADD NEW APPOINTMENT"), call("BSDX OVERBOOK") ]) ])
    one = row(r, "S-SCH-01.1")
    assert_predicate one, :proven?
    assert(one.calls.all? { |c| c["proven"] })
    assert_equal [ "BSDX ADD NEW APPOINTMENT", "BSDX OVERBOOK" ], one.calls.map { |c| c["rpc"] }
  end

  def test_a_failed_or_skipped_spec_leaves_its_scenario_short_and_says_why
    r = report(scheduler: [ spec("Book#test_a", [ "S-SCH-01.1" ], "fail", [ call("BSDX ADD NEW APPOINTMENT", "error") ]),
                            spec("Book#test_b", [ "S-SCH-01.2" ], "skip", [],
                                 skip: "openrpms#1276: scheduler (PROFILE,SCHED) is not given BSDXRPC, which this spec's RPCs run under") ])
    assert_equal "short", row(r, "S-SCH-01.1").status
    assert_match(/Book#test_a failed/, row(r, "S-SCH-01.1").why)
    refute row(r, "S-SCH-01.1").calls.first["proven"]
    assert_match(/skipped: openrpms#1276: .* not given BSDXRPC/, row(r, "S-SCH-01.2").why)
  end

  # XUPROGMODE answers under every option, so the operator's answers count toward no scenario.
  def test_a_scenario_declared_only_as_the_operator_counts_for_nothing
    r = report(operator: [ spec("CoverageWrite#test_a", [ "S-REG-02.14" ], "pass", [ call("BQI PATIENT INSURANCE") ]) ])
    short = row(r, "S-REG-02.14")
    assert_equal "short", short.status
    assert_match(/declared only as operator .*, not as front_desk_clerk/, short.why)
    assert_equal 0, r.proven
  end

  def test_a_role_with_no_recorded_run_is_short_naming_the_command
    assert_match(/no live run as front_desk_clerk recorded its specs \(rake test:live ROLE=front_desk_clerk\)/,
                 row(report, "S-REG-02.1").why)
  end

  def test_the_headline_counts_declared_pilot_scenarios_and_names_stories_with_none
    r = report(scheduler: [ spec("Book#test_a", %w[S-SCH-01.1 S-SCH-01.2], "pass", [ call("BSDX ADD NEW APPOINTMENT") ]) ])
    assert_equal %w[S-REG-02.1 S-REG-02.14 S-SCH-01.1 S-SCH-01.2], r.rows.map(&:id), "S-TRI-04.1 is no pilot story's"
    assert_equal "pilot scenarios whose calls are all proven live as their role: 2 of 4 (the scenarios live specs declare, in 3 pilot stories)", r.headline
    assert_equal [ "S-SGN-01" ], r.undeclared
  end

  def test_rpcs_are_counted_by_the_roles_that_got_them_answered
    r = report(scheduler: [ spec("Book#test_a", [ "S-SCH-01.1" ], "pass", [ call("BSDX ADD NEW APPOINTMENT"), call("BSDX OVERBOOK", "refused") ]) ],
               operator: [ spec("CoverageWrite#test_a", [], "pass", [ call("BQI PATIENT INSURANCE"), call("BSDX ADD NEW APPOINTMENT") ]) ])
    counts = S.rpc_counts(r, [ "BSDX ADD NEW APPOINTMENT", "BSDX OVERBOOK", "BQI PATIENT INSURANCE", "UNUSED" ])
    assert_equal({ roles: 1, operator_only: 1, registered: 4 }, counts)
  end

  def test_summaries_are_read_at_any_depth_and_a_summary_without_specs_adds_none
    Dir.mktmpdir("scenarios") do |dir|
      FileUtils.mkdir_p(File.join(dir, "live-scheduler/coverage/live"))
      File.write(File.join(dir, "live-scheduler/coverage/live/scheduler.json"),
                 JSON.generate("role" => "scheduler", "build" => "b", "specs" => [ spec("A#t", [], "pass", []) ]))
      File.write(File.join(dir, "provider.json"), JSON.generate("role" => "provider", "build" => "b", "runs" => 3))
      File.write(File.join(dir, "broken.json"), "{nope")
      got = S.load_summaries(dir)
      assert_equal [ "scheduler" ], got.keys
      assert_equal 1, got["scheduler"]["specs"].size
    end
  end

  # A real summary: rake test:live ROLE=front_desk_clerk on a throwaway container of bcer-9.0-20261119-f67498c-ydb
  # (2026-11-22), trimmed to the specs that declare an S-REG-02 scenario, judged with this checkout's declarations.
  def test_the_registration_scenarios_are_proven_from_a_real_run
    r = S.report(pilot: S.load_pilot(File.join(ROOT, "data/rpc_coverage/pilot.yml")), plan: LiveSpec.scenario_plan(root: ROOT),
                 summaries: S.load_summaries(File.join(ROOT, "test/fixtures/rpc_coverage/scenarios")))
    %w[S-REG-02.6 S-REG-02.8 S-REG-02.9].each do |id|
      one = row(r, id)
      assert_predicate one, :proven?, one.why
      assert(one.calls.any? { |c| c["rpc"] == "AGG ADD NEW PATIENT" && c["outcome"] == "answered" }, one.calls.inspect)
    end
    assert_includes r.undeclared, "S-SCH-04"
  end

  # The committed pilot list names stories and roles that exist.
  def test_the_pilot_list_names_test_roles
    pilot = S.load_pilot(File.join(ROOT, "data/rpc_coverage/pilot.yml"))
    assert_equal 10, pilot.size
    assert(pilot.values.all? { |role| RpmsRpc::TestRoles[role] }, pilot.inspect)
    assert(pilot.keys.all? { |story| story.match?(S::STORY) })
  end

  # What the specs in this checkout declare, read from their `proves` lines.
  def test_the_specs_declarations_are_well_formed_scenario_ids
    plan = LiveSpec.scenario_plan(root: ROOT)
    refute_empty plan
    plan.each_value do |d|
      refute_empty d[:roles]
      assert(d[:scenarios].all? { |id| id.match?(LiveSpec::SCENARIO_ID) }, d.inspect)
    end
  end
end
