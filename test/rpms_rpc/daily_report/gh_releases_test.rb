# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc/daily_report"

# rpms-rpc#365 panel round 1: gh api --paginate --slurp release pages flatten to one list.
class RpmsRpc::DailyReport::GhReleasesTest < Minitest::Test
  PAGE_ONE = [
    { "tag_name" => "bcer-9.0-20260101-aaa-ydb", "published_at" => "2026-01-02T00:00:00Z",
      "draft" => false, "prerelease" => false }
  ].freeze
  PAGE_TWO = [
    { "tag_name" => "bcer-9.0-20260201-bbb-ydb", "published_at" => "2026-02-01T12:00:00Z",
      "draft" => false, "prerelease" => false }
  ].freeze

  def test_slurp_paginate_json_flattens_page_arrays_to_one_release_list
    body = JSON.generate([ PAGE_ONE, PAGE_TWO ])
    releases = RpmsRpc::DailyReport::GhReleases.parse_api_body(body)

    assert_equal 2, releases.size
    tags = releases.map { |release| release["tag_name"] }
    assert_equal %w[bcer-9.0-20260101-aaa-ydb bcer-9.0-20260201-bbb-ydb], tags
  end

  def test_slurp_paginate_json_accepts_a_single_top_level_page_array
    body = JSON.generate([ PAGE_ONE ])
    releases = RpmsRpc::DailyReport::GhReleases.parse_api_body(body)

    assert_equal 1, releases.size
    assert_equal "bcer-9.0-20260101-aaa-ydb", releases.first["tag_name"]
  end

  def test_gh_api_argv_includes_paginate_and_slurp
    argv = RpmsRpc::DailyReport::GhReleases.gh_api_argv

    assert_includes argv, "--paginate"
    assert_includes argv, "--slurp"
    assert_includes argv, RpmsRpc::DailyReport::OPS_RELEASES
  end
end
