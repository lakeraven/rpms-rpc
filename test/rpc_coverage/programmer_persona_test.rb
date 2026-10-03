# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../tools/rpc_coverage/rpc_coverage"
require_relative "../../tools/rpc_coverage/html_report"

# RPC coverage measured for a programmer user too (rpms-rpc#335). The headline stays the
# least-privilege user's; the programmer run only classifies what that user could not reach.
class RpcCoverageProgrammerPersonaTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rpc-coverage-persona")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def registry(*names)
    path = File.join(@dir, "bcer-test.txt")
    File.write(path, "# source: fixture\n#{names.join("\n")}\n")
    RpcCoverage.load_registry(path)
  end

  def evidence(rpcs, persona: nil)
    run = { "at" => "2026-10-03T00:00:00Z", "host_label" => "fixture" }
    run["persona"] = persona if persona
    { "backend" => "fixture", "runs" => [ run ], "rpcs" => rpcs }
  end

  def ok = { "outcome" => "ok" }
  def err(text = "boom") = { "outcome" => "error", "error" => text }

  # Least-privilege: A covered, B access denied, C M error, D timed out, E/F never sent.
  # Programmer: A ok, B ok, C same M error, D ok, E ok, F error.
  def report(programmer: :default)
    reg = registry("A ONE", "B DENIED", "C BROKEN", "D TIMEOUT", "E UNSENT", "F UNSENT", "G NOWHERE", "H EXCLUDED")
    lp = evidence({ "A ONE" => ok, "B DENIED" => err("4 Access denied for remote procedure: B DENIED"),
                    "C BROKEN" => err("LVUNDEF"), "D TIMEOUT" => err("RpcTimeoutError: timed out after 30s") },
                  persona: "least_privilege")
    if programmer == :default
      programmer = evidence({ "A ONE" => ok, "B DENIED" => ok, "C BROKEN" => err("LVUNDEF"), "D TIMEOUT" => ok,
                              "E UNSENT" => ok, "F UNSENT" => err, "H EXCLUDED" => ok }, persona: "programmer")
    end
    RpcCoverage.compute(registry: reg, declared: { "E UNSENT" => [ "lib/x.rb:1" ], "F UNSENT" => [ "lib/x.rb:2" ] },
                        evidence: lp, exclusions: { "H EXCLUDED" => "gui_plumbing" }, backend: "fixture",
                        programmer: programmer)
  end

  # --- AC1: the persona label -------------------------------------------------------------------

  def test_persona_defaults_to_least_privilege_and_refuses_anything_else
    assert_equal "least_privilege", RpcCoverage.persona(nil)
    assert_equal "least_privilege", RpcCoverage.persona("")
    assert_equal "programmer", RpcCoverage.persona("programmer")
    assert_raises(RpcCoverage::Error) { RpcCoverage.persona("admin") }
  end

  def test_the_persona_is_a_run_metadata_key
    assert_includes RpcCoverage::RUN_KEYS, "persona"
    assert_empty RpcCoverage.evidence_problems(evidence({}, persona: "programmer"), persona: "programmer")
  end

  # --- AC2: the claim is checked against XUPROGMODE ---------------------------------------------

  def test_programmer_must_hold_xuprogmode_and_least_privilege_must_not
    assert_nil RpcCoverage.persona_problem("programmer", holds_progmode: true)
    assert_nil RpcCoverage.persona_problem("least_privilege", holds_progmode: false)
    assert_match(/does not hold XUPROGMODE/, RpcCoverage.persona_problem("programmer", holds_progmode: false))
    assert_match(/holds XUPROGMODE/, RpcCoverage.persona_problem("least_privilege", holds_progmode: true))
  end

  def test_holds_progmode_reads_the_orwu_haskey_reply_lines
    assert RpcCoverage.holds_progmode?([ "1" ])
    refute RpcCoverage.holds_progmode?([ "0" ])
    refute RpcCoverage.holds_progmode?([])
    refute RpcCoverage.holds_progmode?([ "4 Access denied for remote procedure: ORWU HASKEY" ])
  end

  # --- AC3: where each persona's evidence lives -------------------------------------------------

  def test_least_privilege_keeps_its_path_and_programmer_is_written_beside_it
    assert_equal "/d/local-ydb-0930.json", RpcCoverage.evidence_path("/d", "local-ydb-0930", "least_privilege")
    assert_equal "/d/local-ydb-0930.programmer.json", RpcCoverage.evidence_path("/d", "local-ydb-0930", "programmer")
  end

  def test_a_file_whose_runs_name_the_other_persona_is_refused
    assert_match(/run 0 is persona "programmer", not "least_privilege"/,
                 RpcCoverage.evidence_problems(evidence({}, persona: "programmer"), persona: "least_privilege").first)
    assert_match(/run 0 is persona "least_privilege", not "programmer"/,
                 RpcCoverage.evidence_problems(evidence({}, persona: "least_privilege"), persona: "programmer").first)
  end

  def test_least_privilege_runs_from_before_the_label_are_accepted_but_a_programmer_file_needs_it
    assert_empty RpcCoverage.evidence_problems(evidence({}), persona: "least_privilege")
    assert_match(/run 0 is persona nil, not "programmer"/,
                 RpcCoverage.evidence_problems(evidence({}), persona: "programmer").first)
  end

  def test_the_programmer_file_has_the_same_closed_schema_and_secrets_check
    ev = evidence({ "A ONE" => err("SECRETCODE") }, persona: "programmer").merge("verify" => "x")
    problems = RpcCoverage.evidence_problems(ev, secrets: [ "SECRETCODE" ], persona: "programmer")
    assert(problems.any? { |p| p.include?("unexpected keys: verify") })
    assert_includes problems, "live evidence contains a sign-on code"
  end

  # --- AC4: programmer evidence never changes the headline --------------------------------------

  def test_the_headline_is_the_least_privilege_number_with_or_without_programmer_evidence
    with = report
    without = report(programmer: nil)
    assert_equal 1, with.covered
    assert_equal with.one_liner, without.one_liner
    assert_equal with.counts, without.counts
    assert_in_delta without.percent, with.percent
  end

  # --- AC5 + AC6: the programmer class of every RPC least-privilege did not cover ---------------

  def test_each_uncovered_rpc_gets_a_programmer_class
    by_name = report.rows.to_h { |r| [ r[:name], r[:programmer] ] }
    assert_equal({ "A ONE" => nil, "B DENIED" => "permission_gap", "C BROKEN" => "errors_for_both",
                   "D TIMEOUT" => "permission_gap", "E UNSENT" => "programmer_only",
                   "F UNSENT" => "errors_as_programmer", "G NOWHERE" => "untested_as_programmer",
                   "H EXCLUDED" => nil }, by_name)
  end

  def test_the_summary_prints_the_permission_gap_count_and_names
    r = report
    assert_equal [ "B DENIED", "D TIMEOUT" ], r.permission_gaps
    text = r.programmer_lines.join("\n")
    assert_includes text, "permission gaps (answer only for a programmer): 2"
    assert_includes text, "B DENIED"
    assert_includes text, "D TIMEOUT"
    assert_includes text, "programmer_only"
    assert_equal({ present: true, counts: { "errors_as_programmer" => 1, "errors_for_both" => 1, "permission_gap" => 2,
                                            "programmer_only" => 1, "untested_as_programmer" => 1 },
                   permission_gaps: [ "B DENIED", "D TIMEOUT" ] }, r.to_h[:programmer])
  end

  def test_the_tsv_carries_the_programmer_class
    lines = report.tsv.lines(chomp: true)
    assert_equal "name\tstatus\tdetail\tprogrammer", lines.find { |l| l.start_with?("name\t") }
    row = lines.find { |l| l.start_with?("B DENIED\t") }.split("\t", -1)
    assert_equal [ "B DENIED", "live_error", "4 Access denied for remote procedure: B DENIED", "permission_gap" ], row
    assert_equal "", lines.find { |l| l.start_with?("A ONE\t") }.split("\t", -1).last
  end

  def test_the_html_line_shows_the_programmer_class
    row = report.rows.find { |r| r[:name] == "B DENIED" }
    assert_match(/B DENIED\s+live_error\s+permission_gap\s+4 Access denied/, RpcCoverage::Html.line_text(row))
  end

  # --- AC7: no programmer evidence is not an error ----------------------------------------------

  def test_missing_programmer_evidence_still_gives_the_headline_and_says_so
    r = report(programmer: nil)
    assert(r.rows.all? { |row| row[:programmer].nil? })
    assert_empty r.permission_gaps
    assert_match(/programmer evidence: none/, r.programmer_lines.first)
    assert_equal({ present: false }, r.to_h[:programmer])
    assert_empty RpcCoverage.gate_problems(r, max_unregistered: 0)
  end
end
