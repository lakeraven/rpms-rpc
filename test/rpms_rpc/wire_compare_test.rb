# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "digest"
require "yaml"
require "rpms_rpc/wire_capture"

# RpmsRpc::WireCapture.compare (rpms-ops#975): a scratch capture against the
# committed fixtures, so a drifted capture is visible before it replaces one.
# The inputs are the committed fixtures themselves (real captures), copied to
# a scratch directory and changed one way per test.
#
# Rows are keyed by fixture name (the file basename), not by RPC (#700): two
# fixture files that call the same RPC with different inputs are two rows.
class RpmsRpc::WireCompareTest < Minitest::Test
  COMMITTED = RpmsRpc::WireCapture::FIXTURES_DIR

  def setup
    @dir = Dir.mktmpdir("wire-compare")
    FileUtils.cp(Dir.glob(File.join(COMMITTED, "*.yml")), @dir)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def verdicts(committed = COMMITTED)
    RpmsRpc::WireCapture.compare(committed, @dir).to_h { |fixture_name, verdict, *| [ fixture_name, verdict ] }
  end

  def rewrite(file)
    path = File.join(@dir, file)
    data = YAML.safe_load_file(path)
    yield data
    data["sha256"] = Digest::SHA256.hexdigest(data["raw_return"]) if data["raw_return"]
    File.write(path, YAML.dump(data))
  end

  def test_an_identical_capture_is_same_for_every_called_rpc_and_omits_routine_cites
    v = verdicts
    with_raw = RpmsRpc::WireCapture::Fixture.load_all(COMMITTED).select(&:raw_return)
                                            .map { |f| File.basename(f.path, ".yml") }.sort
    refute_empty with_raw
    assert_equal with_raw, v.keys.sort
    assert_equal [ "SAME" ], v.values.uniq
  end

  def test_a_changed_frame_header_alone_is_same_rows
    rewrite("behoencx-fetch.yml") { |d| d["raw_return"] = d["raw_return"].sub(/\A\d+/, "99") }
    assert_equal "SAME-ROWS", verdicts["behoencx-fetch"]
  end

  def test_a_changed_data_row_is_different
    rewrite("behoencx-fetch.yml") { |d| d["raw_return"] = d["raw_return"].sub("DEMO PRIMARY CARE", "OTHER CLINIC") }
    assert_equal "DIFFERENT", verdicts["behoencx-fetch"]
  end

  def test_a_committed_capture_missing_from_the_scratch_run_is_not_captured
    FileUtils.rm(File.join(@dir, "orwpt-select.yml"))
    assert_equal "NOT-CAPTURED", verdicts["orwpt-select"]
  end

  def test_a_capture_where_only_a_routine_cite_is_committed_is_new
    raw = YAML.safe_load_file(File.join(COMMITTED, "orwpt-id-info.yml"))["raw_return"]
    rewrite("ddr-gets-entry-data.yml") do |d|
      d["source"] = "live-capture"
      d["raw_return"] = raw
      d["inputs"] ||= []
    end
    assert_equal "NEW", verdicts["ddr-gets-entry-data"]
  end

  # Two fixture files for one RPC (same RPC, different inputs) must not
  # collapse into one row. The committed side is a scratch copy, so nothing
  # is written into test/fixtures/wire_captures/.
  def test_two_fixture_files_for_one_rpc_are_two_rows_keyed_by_fixture_name
    committed = Dir.mktmpdir("wire-compare-committed")
    FileUtils.cp(Dir.glob(File.join(COMMITTED, "*.yml")), committed)
    original = YAML.safe_load_file(File.join(COMMITTED, "orwpt-select.yml"))
    refute_nil original["raw_return"], "orwpt-select.yml must carry a raw return for this test"
    FileUtils.cp(File.join(COMMITTED, "orwpt-select.yml"), File.join(committed, "synthetic-second.yml"))
    FileUtils.cp(File.join(COMMITTED, "orwpt-select.yml"), File.join(@dir, "synthetic-second.yml"))
    rewrite("synthetic-second.yml") { |d| d["raw_return"] = d["raw_return"].sub(/\^/, "^CHANGED") }
    refute_equal original["raw_return"], YAML.safe_load_file(File.join(@dir, "synthetic-second.yml"))["raw_return"]

    rows = RpmsRpc::WireCapture.compare(committed, @dir)
    v = rows.to_h { |fixture_name, verdict, *| [ fixture_name, verdict ] }
    assert_equal "DIFFERENT", v["synthetic-second"]
    assert_equal "SAME", v["orwpt-select"]
    refute v.key?("ORWPT SELECT"), "rows are keyed by fixture name, not RPC: #{v.keys.inspect}"

    names = rows.map(&:first)
    assert_equal names.sort, names, "rows are sorted by fixture name"
    assert_equal names.uniq, names
    assert_equal [ "synthetic-second", "DIFFERENT", "live-capture", "live-capture" ],
                 rows.find { |row| row.first == "synthetic-second" }
  ensure
    FileUtils.rm_rf(committed) if committed
  end
end
