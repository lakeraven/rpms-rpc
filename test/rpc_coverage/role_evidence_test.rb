# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../../tools/rpc_coverage/rpc_coverage"
require_relative "../../tools/rpc_coverage/html_report"

# RPC coverage recorded per test role (README, Test roles). The number is what the roles other than the
# operator got answered; the operator's run, which XUPROGMODE answers under every option, only classifies
# what they could not reach. Evidence recorded before roles still loads, as legacy.
class RpcCoverageRoleEvidenceTest < Minitest::Test
  ROLES = RpmsRpc::TestRoles
  FIXTURES = File.expand_path("../fixtures/rpc_coverage", __dir__)

  def setup
    @dir = Dir.mktmpdir("rpc-coverage-roles")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def registry(*names)
    path = File.join(@dir, "bcer-test.txt")
    File.write(path, "# source: fixture\n#{names.join("\n")}\n")
    RpcCoverage.load_registry(path)
  end

  def evidence(rpcs, role: nil, persona: nil)
    run = { "at" => "2026-11-22T00:00:00Z", "host_label" => "fixture" }
    run["role"] = role if role
    run["persona"] = persona if persona
    { "backend" => "fixture", "runs" => [ run ], "rpcs" => rpcs }
  end

  def ok = { "outcome" => "ok" }
  def err(text = "boom") = { "outcome" => "error", "error" => text }

  # Provider: A covered, B access denied, C M error, D timed out, E/F never sent.
  # Operator: A ok, B ok, C same M error, D ok, E ok, F error.
  def report(operator: :default)
    reg = registry("A ONE", "B DENIED", "C BROKEN", "D TIMEOUT", "E UNSENT", "F UNSENT", "G NOWHERE", "H EXCLUDED")
    provider = evidence({ "A ONE" => ok, "B DENIED" => err("4 Access denied for remote procedure: B DENIED"),
                          "C BROKEN" => err("LVUNDEF"), "D TIMEOUT" => err("RpcTimeoutError: timed out after 30s") },
                        role: "provider")
    if operator == :default
      operator = evidence({ "A ONE" => ok, "B DENIED" => ok, "C BROKEN" => err("LVUNDEF"), "D TIMEOUT" => ok,
                            "E UNSENT" => ok, "F UNSENT" => err, "H EXCLUDED" => ok }, role: "operator")
    end
    RpcCoverage.compute(registry: reg, declared: { "E UNSENT" => [ "lib/x.rb:1" ], "F UNSENT" => [ "lib/x.rb:2" ] },
                        evidence: provider, exclusions: { "H EXCLUDED" => "gui_plumbing" }, backend: "fixture",
                        operator: operator, as: "provider")
  end

  # --- who a run signs on as ---------------------------------------------------------------------

  def test_role_names_a_test_role_and_nothing_else
    assert_equal :provider, RpcCoverage.run_role("ROLE" => "provider").name
    assert_match(/ROLE is not set/, assert_raises(RpcCoverage::Error) { RpcCoverage.run_role({}) }.message)
    assert_match(/ROLE="admin" is not a test role/, assert_raises(RpcCoverage::Error) { RpcCoverage.run_role("ROLE" => "admin") }.message)
  end

  # The gates' old settings fail by name, pointing at the role to set.
  def test_a_retired_persona_is_refused_naming_the_role
    e = assert_raises(RpcCoverage::Error) { RpcCoverage.run_role("PERSONA" => "least_privilege", "ROLE" => "provider") }
    assert_match(/PERSONA=least_privilege is retired/, e.message)
    e = assert_raises(RpcCoverage::Error) { RpcCoverage.run_role("PERSONA" => "PROV123") }
    assert_match(/set ROLE=provider/, e.message)
  end

  def test_the_pair_is_the_roles_unless_the_target_gives_its_own
    provider = ROLES.fetch(:provider)
    assert_equal [ "PMD123", "PMD123!!" ], RpcCoverage.sign_on_pair(provider, {})
    assert_equal [ "OTHER", "OTHER!!" ], RpcCoverage.sign_on_pair(provider, "RPMS_ACCESS" => "OTHER", "RPMS_VERIFY" => "OTHER!!")
    operator = ROLES.fetch(:operator)
    assert_match(/ROLE=operator needs RPMS_VERIFY/, assert_raises(RpcCoverage::Error) { RpcCoverage.sign_on_pair(operator, {}) }.message)
    assert_equal [ "SYS123", "v" ], RpcCoverage.sign_on_pair(operator, "RPMS_VERIFY" => "v")
  end

  def test_holds_progmode_reads_the_orwu_haskey_reply_lines
    assert RpcCoverage.holds_progmode?([ "1" ])
    refute RpcCoverage.holds_progmode?([ "0" ])
    refute RpcCoverage.holds_progmode?([])
    refute RpcCoverage.holds_progmode?([ "4 Access denied for remote procedure: ORWU HASKEY" ])
  end

  # The account is the role's, and holds XUPROGMODE exactly when its row says so; anything else is refused.
  def test_a_run_under_a_roles_name_must_be_that_roles_account
    provider = ROLES.fetch(:provider)
    operator = ROLES.fetch(:operator)
    assert_nil RpcCoverage.signed_on_problem(provider, user: "PROFILE,MD", holds_progmode: false)
    assert_nil RpcCoverage.signed_on_problem(operator, user: "MANAGER,SYSTEM", holds_progmode: true)
    assert_match(/ROLE=provider signed on as PROVIDER,TEST, not PROFILE,MD/,
                 RpcCoverage.signed_on_problem(provider, user: "PROVIDER,TEST", holds_progmode: false))
    assert_match(/holds XUPROGMODE, which its row does not give it/,
                 RpcCoverage.signed_on_problem(provider, user: "PROFILE,MD", holds_progmode: true))
    assert_match(/does not hold XUPROGMODE, which its row says it holds/,
                 RpcCoverage.signed_on_problem(operator, user: "MANAGER,SYSTEM", holds_progmode: false))
  end

  # --- where each role's evidence lives ---------------------------------------------------------

  def test_each_role_has_its_own_file
    assert_equal "/d/bcer.provider.json", RpcCoverage.evidence_path("/d", "bcer", "provider")
    assert_equal "/d/bcer.operator.json", RpcCoverage.evidence_path("/d", "bcer", :operator)
  end

  def test_a_file_whose_runs_name_another_role_is_refused
    assert_match(/run 0 is "operator", not "provider"/,
                 RpcCoverage.evidence_problems(evidence({}, role: "operator"), role: "provider").first)
    assert_match(/run 0 is "legacy", not "provider"/,
                 RpcCoverage.evidence_problems(evidence({}, persona: "least_privilege"), role: "provider").first)
    assert_match(/carries both role and persona/,
                 RpcCoverage.evidence_problems(evidence({}, role: "provider", persona: "least_privilege")).first)
  end

  def test_runs_from_before_roles_read_as_legacy
    assert_empty RpcCoverage.evidence_problems(evidence({}), role: RpcCoverage::LEGACY)
    assert_empty RpcCoverage.evidence_problems(evidence({}, persona: "programmer"), role: RpcCoverage::LEGACY)
    assert_match(/run 0 is "provider", not "legacy"/,
                 RpcCoverage.evidence_problems(evidence({}, role: "provider"), role: RpcCoverage::LEGACY).first)
  end

  def test_the_closed_schema_and_secrets_check_hold_for_every_role
    ev = evidence({ "A ONE" => err("SECRETCODE") }, role: "operator").merge("verify" => "x")
    problems = RpcCoverage.evidence_problems(ev, secrets: [ "SECRETCODE" ], role: "operator")
    assert(problems.any? { |p| p.include?("unexpected keys: verify") })
    assert_includes problems, "live evidence contains a sign-on code"
  end

  # --- what rake rpc:coverage reads -------------------------------------------------------------

  def write(name, doc) = File.write(File.join(@dir, name), JSON.generate(doc))

  def test_every_role_but_the_operator_makes_the_number
    write("b.provider.json", evidence({ "A" => ok, "B" => err }, role: "provider").merge("backend" => "b"))
    write("b.scheduler.json", evidence({ "B" => ok, "C" => err }, role: "scheduler").merge("backend" => "b"))
    write("b.operator.json", evidence({ "D" => ok }, role: "operator").merge("backend" => "b"))
    write("b.json", evidence({ "Z" => ok }, persona: "least_privilege").merge("backend" => "b"))
    got = RpcCoverage.coverage_inputs(@dir, "b")
    assert_equal "provider, scheduler", got[:as]
    assert_equal({ "A" => "ok", "B" => "ok", "C" => "error" }, got[:evidence]["rpcs"].transform_values { |e| e["outcome"] })
    assert_equal "operator", got[:operator_as]
    assert_equal [ "D" ], got[:operator]["rpcs"].keys
    assert_empty got[:problems]
    refute_includes got[:paths], File.join(@dir, "b.json"), "with a role's file, the legacy file is not read"
  end

  def test_with_no_roles_file_the_legacy_files_are_read_and_say_so
    write("b.json", evidence({ "A" => ok }).merge("backend" => "b"))
    write("b.programmer.json", evidence({ "B" => ok }, persona: "programmer").merge("backend" => "b"))
    got = RpcCoverage.coverage_inputs(@dir, "b")
    assert_match(/legacy least_privilege, recorded before roles/, got[:as])
    assert_match(/legacy programmer/, got[:operator_as])
    assert_empty got[:problems]
    assert_nil RpcCoverage.coverage_inputs(@dir, "none")
  end

  def test_a_file_under_one_roles_name_holding_anothers_runs_is_a_problem
    write("b.provider.json", evidence({ "A" => ok }, role: "scheduler").merge("backend" => "b"))
    assert_match(/b.provider.json: live evidence run 0 is "scheduler", not "provider"/,
                 RpcCoverage.coverage_inputs(@dir, "b")[:problems].first)
  end

  # Real evidence, as rpms-diffs holds it from before roles (rpc-coverage/live/local-ydb-0930*.json, trimmed to
  # its runs and five RPCs), and as rake rpc:live writes it now (a run as the provider against a throwaway
  # container of bcer-9.0-20261119-f67498c-ydb, 2026-11-22).
  def test_the_committed_evidence_loads_from_before_and_after_roles
    legacy = RpcCoverage.coverage_inputs(File.join(FIXTURES, "legacy"), "local-ydb-0930")
    assert_empty legacy[:problems]
    assert_match(/\Alegacy least_privilege/, legacy[:as])
    assert_match(/\Alegacy programmer/, legacy[:operator_as])
    roles = RpcCoverage.coverage_inputs(File.join(FIXTURES, "roles"), "bcer-9.0-20261119-f67498c-ydb")
    assert_empty roles[:problems]
    assert_equal "provider", roles[:as]
    assert_equal [ "provider" ], roles[:evidence]["runs"].map { |r| r["role"] }.uniq
  end

  # --- the operator's evidence never changes the number -----------------------------------------

  def test_the_number_is_the_same_with_or_without_the_operators_evidence
    with = report
    without = report(operator: nil)
    assert_equal 1, with.covered
    assert_equal with.one_liner, without.one_liner
    assert_includes with.one_liner, "as provider"
    assert_equal with.counts, without.counts
    assert_in_delta without.percent, with.percent
  end

  def test_each_uncovered_rpc_gets_an_operator_class
    by_name = report.rows.to_h { |r| [ r[:name], r[:operator] ] }
    assert_equal({ "A ONE" => nil, "B DENIED" => "permission_gap", "C BROKEN" => "errors_for_both",
                   "D TIMEOUT" => "permission_gap", "E UNSENT" => "operator_only",
                   "F UNSENT" => "errors_as_operator", "G NOWHERE" => "untested_as_operator",
                   "H EXCLUDED" => nil }, by_name)
  end

  def test_the_summary_prints_the_permission_gap_count_and_names
    r = report
    assert_equal [ "B DENIED", "D TIMEOUT" ], r.permission_gaps
    text = r.operator_lines.join("\n")
    assert_includes text, "permission gaps (answer only for the operator): 2"
    assert_includes text, "B DENIED"
    assert_includes text, "operator_only"
    assert_equal({ present: true, as: "operator",
                   counts: { "errors_as_operator" => 1, "errors_for_both" => 1, "permission_gap" => 2,
                             "operator_only" => 1, "untested_as_operator" => 1 },
                   permission_gaps: [ "B DENIED", "D TIMEOUT" ] }, r.to_h[:operator])
  end

  def test_the_tsv_carries_the_operator_class
    lines = report.tsv.lines(chomp: true)
    assert_equal "name\tstatus\tdetail\toperator", lines.find { |l| l.start_with?("name\t") }
    row = lines.find { |l| l.start_with?("B DENIED\t") }.split("\t", -1)
    assert_equal [ "B DENIED", "live_error", "4 Access denied for remote procedure: B DENIED", "permission_gap" ], row
  end

  def test_the_html_line_shows_the_operator_class
    row = report.rows.find { |r| r[:name] == "B DENIED" }
    assert_match(/B DENIED\s+live_error\s+permission_gap\s+4 Access denied/, RpcCoverage::Html.line_text(row))
  end

  def test_missing_operator_evidence_still_gives_the_number_and_says_so
    r = report(operator: nil)
    assert(r.rows.all? { |row| row[:operator].nil? })
    assert_match(/operator evidence: none/, r.operator_lines.first)
    assert_equal({ present: false }, r.to_h[:operator])
    assert_empty RpcCoverage.gate_problems(r, max_unregistered: 0)
  end
end
