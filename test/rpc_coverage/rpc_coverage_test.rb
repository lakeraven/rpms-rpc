# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../../tools/rpc_coverage/rpc_coverage"

# rake rpc:coverage (rpms-rpc#270): the computation and every gate, on tiny fixtures.
class RpcCoverageTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rpc-coverage")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write(name, text)
    path = File.join(@dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  def registry(*names, header: "# source: fixture\n")
    RpcCoverage.load_registry(write("registry/bcer-test.txt", header + names.join("\n") + "\n"))
  end

  def evidence(rpcs)
    { "backend" => "fixture", "runs" => [ { "at" => "2026-09-24T00:00:00Z", "host_label" => "fixture" } ],
      "rpcs" => rpcs }
  end

  def report(reg, declared: {}, rpcs: {}, exclusions: {})
    RpcCoverage.compute(registry: reg, declared: declared, evidence: evidence(rpcs),
                        exclusions: exclusions, backend: "fixture")
  end

  # --- the number ------------------------------------------------------------------------------

  def test_covered_means_a_live_ok_on_a_registered_name
    reg = registry("A ONE", "A TWO", "B ONE", "C ONE")
    r = report(reg, declared: { "A ONE" => [ "x:1" ], "A TWO" => [ "x:2" ], "PHANTOM X" => [ "x:3" ] },
                    rpcs: { "A ONE" => { "outcome" => "ok" }, "A TWO" => { "outcome" => "error", "error" => "M ERR" },
                            "PHANTOM X" => { "outcome" => "error", "error" => "Unknown remote procedure" } })
    assert_equal 1, r.covered
    assert_equal 4, r.denominator
    assert_in_delta 25.0, r.percent
    assert_equal({ "covered" => 1, "live_error" => 1, "not_declared" => 2 }, r.counts)
    assert_equal [ "PHANTOM X" ], r.unregistered_used
    assert_equal 2, r.declared_registered
    assert_equal "RPC coverage: 25.0% (1 / 4 registered on bcer-test; 0 excluded) · declared 2 · unregistered names used 1",
                 r.one_liner
  end

  def test_declared_but_never_sent_live_is_declared_untested
    r = report(registry("A ONE"), declared: { "A ONE" => [ "lib/x.rb:9" ] })
    assert_equal [ { name: "A ONE", status: "declared_untested", detail: "lib/x.rb:9" } ], r.rows
  end

  def test_exclusions_leave_the_denominator_and_show_their_reason
    r = report(registry("A ONE", "A TWO"), rpcs: { "A ONE" => { "outcome" => "ok" } },
                                            exclusions: { "A TWO" => "no_routine_on_image" })
    assert_equal 1, r.denominator
    assert_equal 1, r.excluded
    assert_in_delta 100.0, r.percent
    assert_equal "excluded:no_routine_on_image", r.rows.last[:status]
  end

  def test_tsv_has_every_registered_rpc_once_under_a_header_with_the_numbers
    r = report(registry("A ONE", "A TWO", "B ONE"), rpcs: { "A ONE" => { "outcome" => "ok" } })
    lines = r.tsv.lines(chomp: true)
    assert_equal "# #{r.one_liner}", lines.first
    body = lines.drop_while { |l| l.start_with?("#") }.drop(1)
    assert_equal %w[A\ ONE A\ TWO B\ ONE], body.map { |l| l.split("\t").first }
    assert_equal "covered", body.first.split("\t")[1]
  end

  # --- gates -----------------------------------------------------------------------------------

  def test_below_minimum_fails_and_at_minimum_passes
    r = report(registry("A ONE", "A TWO", "A THREE", "A FOUR"), rpcs: { "A ONE" => { "outcome" => "ok" } })
    assert_empty RpcCoverage.gate_problems(r, minimum_percent: 25.0, max_unregistered: 0)
    assert_match(/below the minimum 25.1%/, RpcCoverage.gate_problems(r, minimum_percent: 25.1, max_unregistered: 0).first)
  end

  def test_too_many_unregistered_names_fails
    r = report(registry("A ONE"), declared: { "X ONE" => [ "a" ], "X TWO" => [ "b" ] })
    assert_empty RpcCoverage.gate_problems(r, minimum_percent: 0, max_unregistered: 2)
    assert_match(/2 unregistered names used, over the maximum 1/, RpcCoverage.gate_problems(r, minimum_percent: 0, max_unregistered: 1).first)
  end

  def test_exclusion_of_an_unregistered_name_fails
    problems = RpcCoverage.exclusion_problems({ "NOT HERE" => "gui_plumbing" }, registry("A ONE"))
    assert_match(/"NOT HERE" is not registered/, problems.first)
  end

  def test_exclusion_with_an_unknown_reason_fails
    problems = RpcCoverage.exclusion_problems({ "A ONE" => "too_hard" }, registry("A ONE"))
    assert_match(/unknown reason "too_hard"/, problems.first)
  end

  def test_registry_with_duplicates_or_over_long_names_fails
    problems = RpcCoverage.registry_problems(registry("A ONE", "A ONE", "THIS NAME IS FAR LONGER THAN THIRTY"))
    assert(problems.any? { |p| p.include?("duplicate names: A ONE") })
    assert(problems.any? { |p| p.include?("over 30 chars") })
  end

  def test_empty_registry_fails
    assert_match(/has no names/, RpcCoverage.registry_problems(registry).first)
  end

  def test_registry_header_comments_are_not_names
    reg = registry("A ONE", header: "# source: x\n# sha256: y\n")
    assert_equal [ "A ONE" ], reg.names
    assert_equal 2, reg.header.size
  end

  def test_evidence_carrying_a_sign_on_code_fails
    ev = evidence("A ONE" => { "outcome" => "ok", "error" => "user SECRETCODE" })
    assert_equal [ "live evidence contains a sign-on code" ], RpcCoverage.evidence_problems(ev, secrets: [ "SECRETCODE" ])
    assert_empty RpcCoverage.evidence_problems(ev, secrets: [ nil, "" ])
  end

  def test_evidence_schema_is_closed_so_no_key_can_carry_a_credential
    ev = evidence({}).merge("access" => "X")
    ev["runs"].first["verify"] = "Y"
    problems = RpcCoverage.evidence_problems(ev)
    assert(problems.any? { |p| p.include?("unexpected keys: access") })
    assert(problems.any? { |p| p.include?("run 0 has unexpected keys: verify") })
  end

  def test_evidence_outcome_must_be_ok_or_error
    assert_match(/outcome "maybe"/, RpcCoverage.evidence_problems(evidence("A ONE" => { "outcome" => "maybe" })).first)
  end

  # --- evidence merge --------------------------------------------------------------------------

  def test_merge_keeps_the_best_outcome_per_rpc
    ev = RpcCoverage.empty_evidence("fixture")
    RpcCoverage.merge_run(ev, { "at" => "t1" }, "A ONE" => { "outcome" => "error", "error" => "e1", "last_at" => "t1" },
                                                  "A TWO" => { "outcome" => "ok", "last_at" => "t1" })
    RpcCoverage.merge_run(ev, { "at" => "t2" }, "A ONE" => { "outcome" => "ok", "last_at" => "t2" },
                                                  "A TWO" => { "outcome" => "error", "error" => "e2", "last_at" => "t2" })
    assert_equal "ok", ev["rpcs"]["A ONE"]["outcome"]
    assert_equal "ok", ev["rpcs"]["A TWO"]["outcome"]
    assert_equal 2, ev["runs"].size
  end

  # --- declared names --------------------------------------------------------------------------

  def test_declared_names_reads_mappings_probes_and_rpc_literals
    root = File.join(@dir, "repo")
    write("repo/lib/rpms_rpc/mappings/a.rb", %(DataMapper.define(:a) do |m|\n  m.rpc "A ONE"\nend\n))
    write("repo/lib/rpms_rpc/server_capabilities/x.rb", %(register(:x, [\n  "BB ONE",\n  "BB TWO"\n])\nOTHER = "NOT AN RPC"\nraise Error, "RPC FAILED HERE"\n))
    write("repo/lib/rpms_rpc/cia_client.rb", %(pk("RPC"), pk("CIANBRPC AUTH")\nSIGNON = "CIANB MAIN MENU"\n))
    write("repo/lib/rpms_rpc/mock_client.rb", %(call_rpc("MOCK ONLY")\n))
    names = RpcCoverage.declared_names(root).keys.sort
    assert_equal [ "A ONE", "BB ONE", "BB TWO", "CIANBRPC AUTH" ], names
  end

  def test_the_pinned_registry_and_config_in_this_repo_pass_their_own_gates
    root = File.expand_path("../..", __dir__)
    cfg = YAML.safe_load_file(File.join(root, "data/rpc_coverage/config.yml"))
    reg = RpcCoverage.load_registry(File.join(root, cfg.fetch("registry")))
    assert_empty RpcCoverage.registry_problems(reg)
    assert_empty RpcCoverage.exclusion_problems(RpcCoverage.load_exclusions(File.join(root, "data/rpc_coverage/exclusions.yml")), reg)
    ev = RpcCoverage.load_evidence(File.join(root, "data/rpc_coverage/live/#{cfg.fetch('backend')}.json"), cfg.fetch("backend"))
    assert_empty RpcCoverage.evidence_problems(ev)
  end
end
