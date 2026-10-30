# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/daily_report"

# rpms-rpc#365: markdown summary for the daily report file.
class RpmsRpc::DailyReport::RenderTest < Minitest::Test
  PROV123_ACCESS = "SENTINEL-PROV123-ACCESS-MUST-NOT-APPEAR"
  PROV123_VERIFY = "SENTINEL-PROV123-VERIFY-MUST-NOT-APPEAR"
  SYS123_ACCESS = "SENTINEL-SYS123-ACCESS-MUST-NOT-APPEAR"
  SYS123_VERIFY = "SENTINEL-SYS123-VERIFY-MUST-NOT-APPEAR"
  SECRET_PATTERN = /#{PROV123_ACCESS}|#{PROV123_VERIFY}|#{SYS123_ACCESS}|#{SYS123_VERIFY}/

  def base_input(overrides = {})
    defaults = {
      date: "2026-10-30",
      build_tested: "bcer-9.0-20261030-buildunder-ydb",
      latest_release: "bcer-9.0-20261101-latest-ydb",
      pinned_release: "bcer-9.0-20261012-pinned-ydb",
      rpms_rpc_commit: "abc123def456",
      suites: [
        { name: "rake test", runs: 100, passed: 100, failures: 0, errors: 0, skips: 0, skip_issues: [],
          wall_seconds: 12.3, first_failures: [] },
        { name: "rake test:live (PROV123)", runs: 5, passed: 4, failures: 1, errors: 0, skips: 0,
          skip_issues: [], wall_seconds: 45.0, first_failures: [ "LiveProbe#test_one" ] }
      ],
      coverage: { ran: false, headline: nil, reason: "rpms-diffs checkout missing" }
    }
    RpmsRpc::DailyReport::RenderInput.new(**defaults.merge(overrides))
  end

  def test_renders_date_builds_commit_and_suite_table
    md = RpmsRpc::DailyReport.render(base_input)

    assert_match(/^# Daily RPMS-RPC report — 2026-10-30/m, md)
    assert_match(/build tested.*bcer-9\.0-20261030-buildunder-ydb/m, md)
    assert_match(/latest release.*bcer-9\.0-20261101-latest-ydb/m, md)
    assert_match(/pinned.*bcer-9\.0-20261012-pinned-ydb/m, md)
    assert_match(/rpms-rpc commit.*abc123def456/, md)
    assert_match(/\| rake test \| 100 \| 100 \| 0 \| 0 \| 0 \| \| 12\.3s \|/, md)
    assert_match(/\| rake test:live \(PROV123\) \| 5 \| 4 \| 1 \| 0 \| 0 \| \| 45\.0s \|/, md)
    assert_match(/LiveProbe#test_one/, md)
    assert_match(/rpc:coverage did not run: rpms-diffs checkout missing/, md)
    refute_match(SECRET_PATTERN, md)
  end

  def test_flags_when_build_tested_differs_from_latest_and_pinned
    md = RpmsRpc::DailyReport.render(base_input(build_tested: "bcer-9.0-20261030-other-ydb"))

    assert_match(/build tested differs from latest release/i, md)
    assert_match(/build tested differs from pinned release/i, md)
  end

  def test_includes_coverage_headline_when_present
    md = RpmsRpc::DailyReport.render(base_input(coverage: {
                                            ran: true,
                                            headline: "RPC coverage: 90.0% (9 / 10 registered on local-ydb; 0 excluded)",
                                            reason: nil
                                          }))

    assert_match(/RPC coverage: 90\.0%/, md)
    refute_match(/rpc:coverage did not run/, md)
  end

  def test_escapes_hostile_external_values_in_markdown
    md = RpmsRpc::DailyReport.render(base_input(
                                       build_tested: "evil|tag",
                                       latest_release: "latest<script>",
                                       pinned_release: "pin`quote",
                                       suites: [
                                         { name: "rake test|live", runs: 1, passed: 1, failures: 0, errors: 0, skips: 0,
                                           skip_issues: [ "ops#1|2" ], wall_seconds: 0.1,
                                           first_failures: [ "T#t|`tick" ] }
                                       ]
                                     ))

    refute_match(/<script>/, md)
    md.lines.grep(/^\|/).each do |row|
      assert_operator row.count("|"), :<=, 9, "unescaped pipe broke the table: #{row.inspect}"
    end
    refute_match(/^\| rake test \| live \|/, md)
    refute_match(/`tick/, md)
    refute_match(/ops#1\|2/, md)
    refute_match(/build tested: evil\|tag$/, md)
  end

  def test_escapes_square_brackets_in_markdown
    md = RpmsRpc::DailyReport.render(base_input(
                                       build_tested: "tag[issue]",
                                       suites: [
                                         { name: "rake test[live]", runs: 1, passed: 1, failures: 0, errors: 0, skips: 0,
                                           skip_issues: [ "ops#365[panel]" ], wall_seconds: 0.0, first_failures: [] }
                                       ]
                                     ))

    refute_match(/tag\[issue\]/, md)
    refute_match(/rake test\[live\]/, md)
    refute_match(/ops#365\[panel\]/, md)
    assert_match(/tag&#91;issue&#93;/, md)
  end
end
