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
class RpmsRpc::WireCompareTest < Minitest::Test
  COMMITTED = RpmsRpc::WireCapture::FIXTURES_DIR

  def setup
    @dir = Dir.mktmpdir("wire-compare")
    FileUtils.cp(Dir.glob(File.join(COMMITTED, "*.yml")), @dir)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def verdicts
    RpmsRpc::WireCapture.compare(COMMITTED, @dir).to_h { |name, verdict, *| [ name, verdict ] }
  end

  def rewrite(file)
    path = File.join(@dir, file)
    data = YAML.safe_load_file(path)
    yield data
    data["sha256"] = Digest::SHA256.hexdigest(data["raw_return"]) if data["raw_return"]
    File.write(path, YAML.dump(data))
  end

  def test_an_identical_capture_is_same_for_every_fixture_with_a_raw_return_and_omits_routine_cites
    v = verdicts
    with_raw = RpmsRpc::WireCapture::Fixture.load_all(COMMITTED).select(&:raw_return).map(&:fixture_name).sort
    refute_empty with_raw
    assert_includes with_raw, "tribal-enrollment"
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
    v = verdicts
    assert_equal "NEW", v["ddr-gets-entry-data"]
    assert_equal "SAME", v["tribal-enrollment"],
                 "a second capture of DDR GETS ENTRY DATA must stay its own row"
  end

  def test_a_changed_tribal_enrollment_raw_is_compared_under_its_fixture_name
    rewrite("tribal-enrollment.yml") { |d| d["raw_return"] = "#{d["raw_return"]}X" }
    v = verdicts
    assert_equal "DIFFERENT", v["tribal-enrollment"]
    assert_equal "SAME", v["tribal-eligibility"]
    refute v.key?("DDR GETS ENTRY DATA")
  end
end
