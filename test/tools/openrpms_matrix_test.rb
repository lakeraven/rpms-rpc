# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../../tools/openrpms_matrix"

# tools/openrpms_matrix.rb, behind `rake openrpms:matrix` (rpms-rpc#724). The fixtures are real assets from
# lakeraven/openrpms as published: both 2a9b3fe records (rpms-rpc-live v1) and the releases list for 2a9b3fe,
# 3f5487a and both 312e774 tags (asset names only). No published release carries a v2 record yet, so the v2 column
# is the real ydb record with the fields openrpms bin/rpms_rpc_record.rb writes.
class OpenrpmsMatrixTest < Minitest::Test
  M = OpenrpmsMatrix
  DIR = File.expand_path("../fixtures/openrpms_matrix", __dir__)
  YDB = "bcer-9.0-20261116-2a9b3fe-ydb"
  IRIS = "bcer-9.0-20261116-2a9b3fe-iris"

  def fixture(name) = JSON.parse(File.read(File.join(DIR, name)))
  def record(tag) = fixture("#{tag}-rpms-rpc-live.json")
  def column(tag, rec = record(tag)) = M::Column.new(tag: tag, engine: tag[/(ydb|iris)\z/], record: rec)

  def v2(rec)
    rpcs = rec["rpcs"].to_h { |n, e| [ n, { "verdict" => e["outcome"] == "ok" ? "pass" : "fail" } ] }
    rpcs["ORWU VALIDSIG"] = { "verdict" => "known-failure", "issue" => "https://github.com/lakeraven/openrpms/issues/1" }
    rpcs["XUS SIGNON SETUP"] = { "verdict" => "not-run", "why" => "no case sends it" }
    rec.merge("record" => "rpms-rpc-live.v2", "rpcs" => rpcs)
  end

  def test_the_newest_releases_with_a_record_come_first_and_n_bounds_them
    tags = M.releases(fixture("releases.json"), 3).map { |r| r["tag_name"] }
    assert_equal [ IRIS, YDB, "bcer-9.0-20261113-3f5487a-iris" ], tags
    refute_includes M.releases(fixture("releases.json"), 99).map { |r| r["tag_name"] }, "bcer-9.0-20261111-312e774-ydb", "it carries no record"
  end

  def test_a_v1_record_reads_ok_as_pass_and_error_as_fail
    cells = M.cells(record(YDB))
    assert_equal record(YDB)["rpcs"].size, cells.size
    assert_equal({ "verdict" => "pass" }, cells["BEHOCIR GETNUM"])
    assert(cells.values.all? { |c| %w[pass fail].include?(c["verdict"]) })
  end

  def test_rows_are_the_rpcs_some_release_exercised_with_a_cell_per_release_and_engine
    m = M.matrix([ column(IRIS), column(YDB, v2(record(YDB))) ])
    assert_equal [ IRIS, YDB ], m[:columns].map(&:tag)
    assert_equal %w[iris ydb], m[:columns].map(&:engine)
    assert_equal m[:rows].keys.sort, m[:rows].keys
    assert_equal [ nil, { "verdict" => "known-failure", "issue" => "https://github.com/lakeraven/openrpms/issues/1" } ], m[:rows]["ORWU VALIDSIG"]
    refute m[:rows].key?("XUS SIGNON SETUP"), "an RPC no release exercised is not a row"
    assert(m[:rows].values.all? { |row| row.size == 2 })
  end

  def test_the_page_names_every_release_and_links_a_known_failure_to_its_issue
    page = M.html(M.matrix([ column(IRIS), column(YDB, v2(record(YDB))) ]))
    assert_match(/\A<!doctype html>/, page)
    assert_includes page, "title=\"#{IRIS} (record v1)\""
    assert_includes page, "title=\"#{YDB} (record v2)\""
    assert_includes page, "href=\"https://github.com/lakeraven/openrpms/issues/1\">known-failure</a>"
    assert_includes page, "class=\"pass\""
    refute_includes page, "<script"
  end
end
