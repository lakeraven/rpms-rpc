# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "rpms_rpc"
require_relative "../../tools/rpc_inventory/rpc_inventory"

# tools/rpc_inventory, behind `rake rpc:inventory`. The fixtures are real assets of lakeraven/openrpms as published
# for bcer-9.0-20261116-2a9b3fe on both engines, byte for byte: <tag>-rpcs.json (gzipped with `gzip -9 -n`),
# <tag>-rpms-rpc-live.json, <tag>-harness.json and both <tag>-conformance-<label>.jsonl (-programmer and -least_privilege: they were gated before roles). rpms-rpc's side is this
# checkout, read the way rake rpc:api_coverage reads it.
class RpcInventoryTest < Minitest::Test
  I = RpcInventory
  ROOT = File.expand_path("../..", __dir__)
  DIR = File.expand_path("../fixtures/rpc_inventory", __dir__)
  IRIS = "bcer-9.0-20261116-2a9b3fe-iris"
  YDB = "bcer-9.0-20261116-2a9b3fe-ydb"

  # Read once for the class: each render runs the api_coverage analysis over lib/.
  def self.cached = @cached ||= {}
  def cached(key) = self.class.cached.key?(key) ? self.class.cached[key] : (self.class.cached[key] = yield)
  def releases = cached(:releases) { [ I.load_release(DIR, IRIS), I.load_release(DIR, YDB) ] }
  def coverage = cached(:coverage) { I.coverage(ROOT, surface: releases.last.surface) }
  def files = cached(:files) { I.render(releases, ROOT, cov: coverage) }
  def rows = cached(:rows) { I.rows(releases, coverage, I.clients(ROOT), I.reviewed_exclusions(ROOT)) }
  def row(name) = rows.find { |r| r["rpc"] == name } || flunk("no row for #{name}")

  # The releases are read again from disk; the lib/ analysis is reused (required_rpcs_test pins its output).
  def test_the_same_inputs_give_the_same_bytes
    again = I.render([ I.load_release(DIR, IRIS), I.load_release(DIR, YDB) ], ROOT, cov: coverage)
    assert_equal files.keys, again.keys
    files.each { |name, body| assert body == again[name], "#{name} differs between two runs on the same inputs" }
  end

  def test_one_row_per_registered_rpc_in_byte_order
    csv_lines = files["rpc-inventory.csv"].lines
    assert_equal I::COLUMNS.join(","), csv_lines.first.chomp
    assert_equal 5592, rows.size
    assert_equal rows.map { |r| r["rpc"] }.sort_by(&:b), rows.map { |r| r["rpc"] }
    assert_equal 5593, csv_lines.size
  end

  # A known row on IRIS: ORWU USERINFO is registered and callable, served by CIAV VUECENTRIC, sent by read wrappers
  # that live specs call, and passed the IRIS gate's live run.
  def test_orwu_userinfo_on_iris
    r = row("ORWU USERINFO")
    assert_equal %w[yes client-callable pass], r.values_at("registered_iris", "reach_iris", "live_iris")
    assert_equal "USERINFO^ORWU", r["entry_point"]
    assert_includes r["contexts"].split("; "), "CIAV VUECENTRIC"
    assert_includes r["wrappers"].split("; "), "UserManagement.find"
    assert_includes r["wrapper_paths"].split("; "), "GET /users/{duz}"
    assert_equal %w[read get wrapper], r.values_at("read_write", "operation", "operation_source")
    refute_empty r["live_tests"]
    assert_equal "least_privilege=answered;programmer=answered", r["wire_cases_iris"]
  end

  # A release gated since roles carries -conformance-operator and -provider; with both sets on it (a release
  # gated before roles, then gated again), the roles' records are the ones read. The records are the fixture's
  # own, under the names the gate writes now.
  def test_a_release_gated_since_roles_shows_each_leg_by_its_role
    Dir.mktmpdir("rpc-inventory-roles") do |dir|
      Dir[File.join(DIR, "#{IRIS}-*")].each { |f| FileUtils.cp(f, dir) }
      { "programmer" => "operator", "least_privilege" => "provider" }.each do |legacy, role|
        FileUtils.cp(File.join(DIR, "#{IRIS}-conformance-#{legacy}.jsonl"), File.join(dir, "#{IRIS}-conformance-#{role}.jsonl"))
      end
      release = I.load_release(dir, IRIS)
      assert_equal %w[operator provider], release.cases.keys
      assert_equal "operator=answered;provider=answered", I.wire_cells(release)["ORWU USERINFO"]
      FileUtils.rm(Dir[File.join(dir, "#{IRIS}-conformance-*.jsonl")])
      assert_nil I.case_labels(dir, IRIS)
      assert_empty I.load_release(dir, IRIS).cases
    end
  end

  # A known row on YottaDB: ORWRP REPORT TEXT passed on IRIS and failed on YottaDB in the same build's live run.
  def test_orwrp_report_text_fails_on_ydb_only
    r = row("ORWRP REPORT TEXT")
    assert_equal %w[yes yes], r.values_at("registered_iris", "registered_ydb")
    assert_equal "pass", r["live_iris"]
    assert_equal "fail", r["live_ydb"]
  end

  def test_an_rpc_the_live_record_does_not_cover_is_not_run
    r = row("ADE APPT ADD")
    assert_equal %w[no-routine not-run], r.values_at("reach_ydb", "live_ydb")
    assert_empty r["wrappers"]
  end

  # The two registries differ only in the formals BMCRPC2's SETREFRL and UPREF carry on each engine.
  def test_the_engines_register_the_same_rpcs_and_differ_in_formals_only
    d = I.differences(releases)
    assert_empty d[:iris_only]
    assert_empty d[:ydb_only]
    assert_empty d[:reach]
    assert_empty d[:contexts]
    assert_equal [ "BMC ADD REFERRAL", "BMC UPDATE REFERRAL" ], d[:formals].map(&:first)
    assert_includes files["rpc-inventory.md"], "- entry-point formals differs on 2:"
  end

  # CIAVMRPC GETPAR: 31 calls in the 2026-09-23 session and 23 in the 2026-10-21 one (data/rpc_inventory/clients/
  # vuecentric-observed.tsv), 16 in the 2026-09-15 one (data/rpc_tiers/observed/). It is also a reviewed gui_plumbing
  # exclusion, which the column carries beside the reach class.
  def test_vuecentric_calls_and_sessions_sum_the_recorded_sessions
    r = row("CIAVMRPC GETPAR")
    assert_equal %w[observed 70 3 gui_plumbing], r.values_at("vuecentric", "vuecentric_calls", "vuecentric_sessions", "excluded")
    assert_equal %w[observed 6 2], row("BEHOPTCX LAST").values_at("vuecentric", "vuecentric_calls", "vuecentric_sessions")
    named = row("AMHBH ENCOUNTER FORM")
    assert_equal [ "named", "", "" ], named.values_at("vuecentric", "vuecentric_calls", "vuecentric_sessions")
    assert_includes files["rpc-inventory.md"], "`CIAVMRPC GETPAR` (70), `ORWDX DGNM` (64)"
  end

  # Only the reviewed reasons fill the column: an RPC the release's reach classes rule out (ADE APPT ADD has no
  # routine) is blank, since reach_* already says so.
  def test_excluded_carries_the_reviewed_reasons_only
    assert_equal 29, rows.count { |r| r["excluded"] == "gui_plumbing" }
    assert_equal [ "", "gui_plumbing" ], rows.map { |r| r["excluded"] }.uniq.sort
    assert_equal %w[gui_plumbing write_needs_fixture], I::REVIEWED
    assert_equal "", row("ADE APPT ADD")["excluded"]
    assert_includes files["rpc-inventory.md"], "- Excluded by review, not to be wrapped: gui_plumbing 29; sent by a wrapper anyway: none."
  end

  # A reviewed exclusion on an RPC a wrapper sends stays in the row and is named in the summary.
  def test_an_excluded_rpc_a_wrapper_sends_is_reported
    excluded = I.reviewed_exclusions(ROOT).merge("ORWU USERINFO" => "gui_plumbing")
    rs = I.rows(releases, coverage, I.clients(ROOT), excluded)
    r = rs.find { |x| x["rpc"] == "ORWU USERINFO" }
    assert_equal "gui_plumbing", r["excluded"]
    refute_empty r["wrappers"]
    assert_equal [ [ "ORWU USERINFO", "gui_plumbing" ] ], I.summary(rs, releases)[:excluded_wrapped]
  end

  # The header the inventory had before excluded and the VueCentric counts (rpms-rpc efa4ba23).
  HEADER_EFA4BA23 = "rpc,package_prefix,package,registered_iris,registered_ydb,reach_iris,reach_ydb,contexts,entry_point," \
                    "vuecentric,bprm,lakeraven_ehr,wrappers,wrapper_paths,rpc_path,resource,operation,operation_source,read_write," \
                    "live_tests,captured_replies,live_iris,live_ydb,wire_cases_iris,wire_cases_ydb\n"

  def test_release_notes_name_both_tags_and_the_column_change
    header = files["rpc-inventory.csv"].lines.first
    tags = { "iris" => IRIS, "ydb" => YDB }
    notes = I.release_notes(tags, header, { tag: "v0.4.0", header: HEADER_EFA4BA23 })
    assert_includes notes, "`bundle exec rake rpc:inventory IRIS=#{IRIS} YDB=#{YDB}`"
    assert_includes notes, "Columns changed since `v0.4.0`: added `vuecentric_calls`, `vuecentric_sessions`, `excluded`; removed or renamed none."
    assert_includes I.release_notes(tags, header, { tag: "v0.5.0", header: header }), "Columns: the same #{I::COLUMNS.size} as `v0.5.0`."
    assert_includes I.release_notes(tags, header, nil), "the first release to carry the inventory"
  end

  # A re-run replaces the section; the rest of the release's notes stay as written.
  def test_the_notes_section_is_replaced_not_repeated
    tags = { "iris" => IRIS, "ydb" => YDB }
    first = I.splice_notes("**Added:** a thing.\n", I.release_notes(tags, HEADER_EFA4BA23, nil))
    header = files["rpc-inventory.csv"].lines.first
    again = I.splice_notes(first, I.release_notes(tags, header, nil))
    assert again.start_with?("**Added:** a thing.\n\n#{I::NOTES_BEGIN}")
    assert_equal 1, again.scan(I::NOTES_BEGIN).size
    assert_includes again, "Columns (#{I::COLUMNS.size};"
  end

  def test_the_previous_release_is_the_newest_published_one_before_with_the_csv
    csv = [ { "name" => "rpc-inventory.csv" } ]
    list = [
      { "tag_name" => "v0.6.0", "draft" => false, "prerelease" => false, "published_at" => "2026-12-01T00:00:00Z", "assets" => [] },
      { "tag_name" => "v0.5.1", "draft" => true, "prerelease" => false, "published_at" => nil, "assets" => csv },
      { "tag_name" => "v0.5.0", "draft" => false, "prerelease" => false, "published_at" => "2026-11-25T00:00:00Z", "assets" => csv },
      { "tag_name" => "v0.4.0", "draft" => false, "prerelease" => false, "published_at" => "2026-10-12T19:37:34Z",
        "assets" => [ { "name" => "client-api.openapi.json" } ] }
    ]
    assert_equal "v0.5.0", I.previous_release(list, "v0.6.0")
    assert_nil I.previous_release(list, "v0.5.0")
  end

  def test_the_newest_published_release_per_engine_is_the_default
    list = [
      { "tag_name" => "#{YDB}x", "draft" => false, "prerelease" => false, "published_at" => "2026-11-20T00:00:00Z", "assets" => [] },
      { "tag_name" => "bcer-9.0-20261118-d4547cf-ydb", "draft" => true, "prerelease" => false, "published_at" => nil,
        "assets" => [ { "name" => "bcer-9.0-20261118-d4547cf-ydb-rpcs.json" } ] },
      { "tag_name" => YDB, "draft" => false, "prerelease" => false, "published_at" => "2026-11-16T03:59:25Z",
        "assets" => [ { "name" => "#{YDB}-rpcs.json" } ] },
      { "tag_name" => IRIS, "draft" => false, "prerelease" => false, "published_at" => "2026-11-16T05:57:15Z",
        "assets" => [ { "name" => "#{IRIS}-rpcs.json" } ] },
      { "tag_name" => "bcer-9.0-20261113-3f5487a-iris", "draft" => false, "prerelease" => false,
        "published_at" => "2026-11-15T18:44:55Z", "assets" => [ { "name" => "bcer-9.0-20261113-3f5487a-iris-rpcs.json" } ] }
    ]
    assert_equal({ "iris" => IRIS, "ydb" => YDB }, I.latest_tags(list))
  end

  def test_operations_from_an_rpc_name
    assert_equal "list", I.name_operation("ORQQAL LIST")
    assert_equal "get", I.name_operation("DDR GETS ENTRY DATA")
    assert_equal "create", I.name_operation("BSDX ADD NEW APPOINTMENT")
    assert_equal "delete", I.name_operation("BGOVDLV DEL")
    assert_nil I.name_operation("DDR FILER")
  end
end
