# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../tools/rpc_coverage/rpc_coverage"
require_relative "../../tools/rpc_coverage/html_report"

# rake rpc:coverage_html: how the rpc:coverage rows become SimpleCov files and lines.
class RpcCoverageHtmlTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rpc-coverage-html")
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

  def packages
    RpcCoverage::Html.load_packages(write("packages.txt", <<~PKG))
      # source: fixture
      OR^ORDER ENTRY/RESULTS REPORTING^3.0
      ORWD^ORDER DIALOGS^1
      XWB^RPC BROKER^1.1
    PKG
  end

  def report(*rows)
    names = rows.map(&:first)
    reg = RpcCoverage.load_registry(write("registry/bcer-test.txt", "# source: fixture\n#{names.join("\n")}\n"))
    rpcs = rows.select { |_, s| %w[ok error].include?(s) }.to_h { |n, s| [ n, { "outcome" => s, "error" => "x" } ] }
    excl = rows.select { |_, s| s == "excluded" }.to_h { |n, _| [ n, "gui_plumbing" ] }
    RpcCoverage.compute(registry: reg, declared: {}, evidence: { "backend" => "fixture", "runs" => [], "rpcs" => rpcs },
                        exclusions: excl, backend: "fixture")
  end

  def test_the_longest_package_prefix_claims_a_name
    assert_equal "ORWD", RpcCoverage::Html.package_for("ORWDX SAVE", packages).first
    assert_equal "OR", RpcCoverage::Html.package_for("ORQQPL LIST", packages).first
  end

  def test_a_name_no_package_claims_is_grouped_by_its_own_namespace
    assert_equal [ "AKFR", RpcCoverage::Html::NO_PACKAGE ], RpcCoverage::Html.package_for("AKFRACH GET", packages)
    assert_equal "GMV", RpcCoverage::Html.package_for("GMV VITALS/CAT/QUAL", packages).first
  end

  def test_covered_is_a_hit_other_statuses_are_missed_and_exclusions_are_never_relevant
    assert_equal 1, RpcCoverage::Html.hits("covered")
    %w[live_error declared_untested not_declared].each { |s| assert_equal 0, RpcCoverage::Html.hits(s) }
    assert_nil RpcCoverage::Html.hits("excluded:gui_plumbing")
  end

  def test_one_file_per_package_one_line_per_rpc_in_registry_order
    rep = report([ "ORWDX SAVE", "ok" ], [ "ORWDX LOCK", "error" ], [ "XWB ECHO", "excluded" ], [ "ZZZ ODD", "none" ])
    cov = RpcCoverage::Html.write_sources(rep, packages, File.join(@dir, "src"))

    by_file = cov.transform_keys { |k| File.basename(k) }
    assert_equal %w[ORWD-ORDER-DIALOGS.rpc XWB-RPC-BROKER.rpc ZZZ-not-a-9-4-package.rpc], by_file.keys
    assert_equal [ 1, 0 ], by_file["ORWD-ORDER-DIALOGS.rpc"]["lines"]
    assert_equal [ nil ], by_file["XWB-RPC-BROKER.rpc"]["lines"]
    assert_equal [ 0 ], by_file["ZZZ-not-a-9-4-package.rpc"]["lines"]

    text = File.readlines(File.join(@dir, "src/ORWD-ORDER-DIALOGS.rpc"), chomp: true)
    assert_equal 2, text.size, "one line per RPC, so SimpleCov's line numbers line up with the hits"
    assert_match(/\AORWDX SAVE\s+covered/, text[0])
    assert_match(/\AORWDX LOCK\s+live_error\s+x/, text[1])
  end

  def test_render_writes_a_simplecov_index_whose_total_is_the_headline
    rep = report([ "ORWDX SAVE", "ok" ], [ "ORWDX LOCK", "error" ], [ "XWB ECHO", "excluded" ])
    index = RpcCoverage::Html.render(rep, packages, File.join(@dir, "out"))

    html = File.read(index)
    assert_includes html, "ORWD-ORDER-DIALOGS.rpc"
    assert_includes html, "50.0%", "1 covered of 2 relevant (the excluded RPC is outside the denominator)"
  end

  def test_an_empty_package_list_fails_loudly
    assert_raises(RpcCoverage::Error) { RpcCoverage::Html.load_packages(write("empty.txt", "# nothing\n")) }
  end
end
