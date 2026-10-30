# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "yaml"
require "rpms_rpc/daily_report"

# rpms-rpc#365: pure release choice for rake report:daily.
class RpmsRpc::DailyReport::ReleaseChoiceTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)

  def release(tag:, published_at:, draft: false, prerelease: false)
    { "tag_name" => tag, "published_at" => published_at, "draft" => draft, "prerelease" => prerelease }
  end

  def test_picks_the_newest_non_draft_non_prerelease_bcer_ydb_release
    releases = [
      release(tag: "bcer-8.0-20260101-aaa-ydb", published_at: "2026-01-02T00:00:00Z"),
      release(tag: "bcer-9.0-20260201-bbb-ydb", published_at: "2026-02-01T12:00:00Z"),
      release(tag: "bcer-9.0-20260115-ccc-ydb", published_at: "2026-01-20T00:00:00Z")
    ]
    picked = RpmsRpc::DailyReport::ReleaseChoice.pick(releases)

    assert_equal "bcer-9.0-20260201-bbb-ydb", picked.fetch(:tag)
    assert_equal "2026-02-01T12:00:00Z", picked.fetch(:published_at)
  end

  def test_ignores_draft_prerelease_and_non_ydb_tags
    releases = [
      release(tag: "bcer-9.0-20260301-newest-ydb", published_at: "2026-03-01T00:00:00Z", draft: true),
      release(tag: "bcer-9.0-20260302-beta-ydb", published_at: "2026-03-02T00:00:00Z", prerelease: true),
      release(tag: "bcer-9.0-20260228-iris", published_at: "2026-03-03T00:00:00Z"),
      release(tag: "v1.0.0", published_at: "2026-03-04T00:00:00Z"),
      release(tag: "bcer-9.0-20260215-ok-ydb", published_at: "2026-02-15T00:00:00Z")
    ]
    picked = RpmsRpc::DailyReport::ReleaseChoice.pick(releases)

    assert_equal "bcer-9.0-20260215-ok-ydb", picked.fetch(:tag)
  end

  def test_no_matching_release_raises_instead_of_guessing
    releases = [
      release(tag: "bcer-9.0-20260101-aaa-iris", published_at: "2026-01-01T00:00:00Z"),
      release(tag: "not-a-bcer-tag", published_at: "2026-01-02T00:00:00Z")
    ]

    error = assert_raises(RpmsRpc::DailyReport::ReleaseChoice::NoRelease) do
      RpmsRpc::DailyReport::ReleaseChoice.pick(releases)
    end
    assert_match(/bcer-.*-ydb/i, error.message)
  end

  def test_pinned_release_reads_data_rpc_coverage_config
    Dir.mktmpdir do |tmpdir|
      config_dir = File.join(tmpdir, "data/rpc_coverage")
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "config.yml"), YAML.dump("release" => "bcer-9.0-20260999-synthetic-ydb"))

      assert_equal "bcer-9.0-20260999-synthetic-ydb",
                   RpmsRpc::DailyReport.pinned_release(root: tmpdir)
    end
  end
end
