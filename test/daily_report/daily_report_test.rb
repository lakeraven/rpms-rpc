# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../tools/daily_report/daily_report"

# rake report:daily: the pure parts (rpms-rpc#365). Inputs are real client-side text: a
# `gh release list` page and minitest -v output as captured on 2026-10-03.
class DailyReportTest < Minitest::Test
  # test:live as SYS123 against the 0930 build (verbose lines trimmed).
  LIVE_PASS = <<~OUT
    Run options: -v --seed 8344

    # Running:

    PatientLiveTest#test_find_returns_the_patients_demographics = 0.03 s = .
    PatientUpdateLiveTest#test_update_files_email_and_cell_phone = 0.02 s = S

    Finished in 15.865170s, 1.6388 runs/s, 92.4667 assertions/s.

      1) Skipped:
    PatientUpdateLiveTest#test_update_files_email_and_cell_phone [test/live/patient_update_live_test.rb:44]:
    rpms-rpc#351: filing #2 .133/.134 over DDR FILER raises <LVUNDEF> DFN in DIKC though the value files

    26 runs, 1467 assertions, 0 failures, 0 errors, 1 skips
  OUT

  # One skip, one error, one failure.
  LIVE_FAIL = <<~OUT
    Finished in 0.000578s, 6920.4127 runs/s, 3460.2064 assertions/s.

      1) Skipped:
    PatientLiveTest#test_search_past_the_last_name_is_empty [../ft_test.rb:5]:
    rpms-rpc#351: tracked

      2) Error:
    PatientLiveTest#test_brief_header_projects_the_chart_banner:
    RuntimeError: CIA broker did not answer connect
        ../ft_test.rb:4:in 'PatientLiveTest#test_brief_header_projects_the_chart_banner'

      3) Failure:
    PatientLiveTest#test_find_returns_the_patients_demographics [../ft_test.rb:3]:
    Expected: "DEMO,ONE"
      Actual: "DEMO,TWO"

    4 runs, 2 assertions, 1 failures, 1 errors, 1 skips
  OUT

  def test_the_latest_ydb_release_is_the_newest_published_bcer_ydb_tag
    rows = [
      { "tagName" => "bcer-9.0-20260929-6812fea-iris", "publishedAt" => "2026-10-01T10:00:00Z", "isDraft" => false },
      { "tagName" => "bcer-9.0-20261002-aaaaaaa-ydb", "publishedAt" => "2026-10-02T10:00:00Z", "isDraft" => true },
      { "tagName" => "bcer-9.0-20260929-0db1b06-ydb", "publishedAt" => "2026-09-29T17:16:58Z", "isDraft" => false },
      { "tagName" => "bcer-9.0-20260930-8c88e47-ydb", "publishedAt" => "2026-09-30T19:08:40Z", "isDraft" => false }
    ]
    assert_equal "bcer-9.0-20260930-8c88e47-ydb", DailyReport.latest_ydb_release(rows)
    assert_nil DailyReport.latest_ydb_release(rows.first(2))
  end

  def test_the_build_is_read_from_an_image_tag
    assert_equal "bcer-9.0-20260930-8c88e47-ydb",
                 DailyReport.build_from_image("ghcr.io/lakeraven/rpms-ydb:image-bcer-9.0-20260930-8c88e47-ydb-79ecb8d748ad-681bcfd8f78c-arm64")
    assert_equal "bcer-9.0-20260916-99383c2-ydb", DailyReport.build_from_image("ghcr.io/lakeraven/rpms-ydb:bcer-9.0-20260916-99383c2-ydb")
    assert_nil DailyReport.build_from_image("alpine/socat")
  end

  def test_the_local_image_matches_release_and_arch
    refs = %w[
      ghcr.io/lakeraven/rpms-ydb:image-bcer-9.0-20260930-8c88e47-ydb-79ecb8d748ad-681bcfd8f78c-amd64
      ghcr.io/lakeraven/rpms-ydb:image-bcer-9.0-20260930-8c88e47-ydb-79ecb8d748ad-681bcfd8f78c-arm64
      ghcr.io/lakeraven/rpms-ydb:bcer-9.0-20260916-99383c2-ydb
    ]
    assert_equal refs[1], DailyReport.pick_local_image(refs, "bcer-9.0-20260930-8c88e47-ydb", "arm64")
    assert_equal refs[2], DailyReport.pick_local_image(refs, "bcer-9.0-20260916-99383c2-ydb", "arm64")
    assert_nil DailyReport.pick_local_image(refs, "bcer-9.0-20261007-bbbbbbb-ydb", "arm64")
  end

  def test_the_pinned_build_is_the_registry_file_name
    assert_equal "bcer-9.0-20260913-1a2244c-ydb",
                 DailyReport.pinned_build("registry" => "data/rpc_coverage/registry/bcer-9.0-20260913-1a2244c-ydb.txt")
  end

  def test_a_passing_run_counts_and_names_the_issue_its_skip_tracks
    r = DailyReport.parse_minitest(LIVE_PASS)
    assert_equal [ 26, 25, 0, 0, 1 ], [ r.runs, r.passed, r.failures, r.errors, r.skips ]
    assert_empty r.failed
    assert_equal [ "rpms-rpc#351" ], r.skip_issues
  end

  def test_failures_and_errors_are_named_and_skips_are_not
    r = DailyReport.parse_minitest(LIVE_FAIL)
    assert_equal [ 4, 1, 1, 1, 1 ], [ r.runs, r.passed, r.failures, r.errors, r.skips ]
    assert_equal %w[PatientLiveTest#test_brief_header_projects_the_chart_banner
                    PatientLiveTest#test_find_returns_the_patients_demographics], r.failed
  end

  def test_output_without_a_summary_did_not_finish
    assert_nil DailyReport.parse_minitest("cannot load such file -- rpms_rpc/cia_client (LoadError)\n")
  end

  def test_the_report_renders_builds_suites_failures_and_the_result
    facts = { date: "2026-10-03", time: "2026-10-03 09:00 PDT", build: "bcer-9.0-20260930-8c88e47-ydb",
              latest: "bcer-9.0-20260930-8c88e47-ydb", pinned: "bcer-9.0-20260913-1a2244c-ydb",
              target: "127.0.0.1:19300", commit: "8fc34c3", coverage: "RPC coverage: 0.8%" }
    suites = [
      DailyReport::Suite.new(name: "test:live SYS123", result: DailyReport.parse_minitest(LIVE_PASS), seconds: 16.4, exit_ok: true),
      DailyReport::Suite.new(name: "test:live PROV123", result: DailyReport.parse_minitest(LIVE_FAIL), seconds: 1.0, exit_ok: false),
      DailyReport::Suite.new(name: "rake test", result: nil, seconds: 0.5, exit_ok: false)
    ]
    md = DailyReport.render(facts, suites, max_failed: 1)
    assert_includes md, "- Build tested: bcer-9.0-20260930-8c88e47-ydb (the latest bcer-*-ydb release)"
    assert_includes md, "pinned bcer-9.0-20260913-1a2244c-ydb, tested bcer-9.0-20260930-8c88e47-ydb"
    assert_includes md, "| test:live SYS123 | 26 | 25 | 0 | 0 | 1 (rpms-rpc#351) | 16.4 s |"
    assert_includes md, "| rake test | did not finish | | | | | 0.5 s |"
    assert_includes md, "Failing (first 1 of 2):"
    assert_includes md, "- test:live PROV123: PatientLiveTest#test_brief_header_projects_the_chart_banner"
    refute_includes md, "test_find_returns_the_patients_demographics"
    assert md.end_with?("Result: FAIL\n")
  end

  def test_a_build_other_than_the_latest_says_so
    facts = { build: "bcer-9.0-20260921-e6f4f0c-ydb", latest: "bcer-9.0-20260930-8c88e47-ydb" }
    assert_equal "bcer-9.0-20260921-e6f4f0c-ydb; the latest bcer-*-ydb release is bcer-9.0-20260930-8c88e47-ydb",
                 DailyReport.build_line(facts)
  end
end
