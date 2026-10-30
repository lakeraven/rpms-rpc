# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "rpms_rpc/daily_report"

# rpms-rpc#365: default markdown path beside rpms-diffs (same discovery as rpc:coverage).
class RpmsRpc::DailyReport::PathsTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)

  def test_default_path_under_rpms_diffs_daily_with_sanitized_build
    path = RpmsRpc::DailyReport.default_report_path(
      rpms_diffs_dir: "/tmp/rpms-diffs",
      date: "2026-10-30",
      build: "bcer-9.0/weird:build-ydb"
    )

    assert_equal "/tmp/rpms-diffs/rpc-coverage/daily/2026-10-30-bcer-9.0_weird_build-ydb.md", path
  end

  def test_rpms_diffs_dir_defaults_to_sibling_of_repo
    dir = RpmsRpc::DailyReport.rpms_diffs_dir({}, root: ROOT)

    assert_equal File.expand_path("../rpms-diffs", ROOT), dir
  end

  def test_rpms_diffs_dir_honors_env_override
    dir = RpmsRpc::DailyReport.rpms_diffs_dir({ "RPMS_DIFFS_DIR" => "/var/rpms-diffs" }, root: ROOT)

    assert_equal "/var/rpms-diffs", dir
  end
end
