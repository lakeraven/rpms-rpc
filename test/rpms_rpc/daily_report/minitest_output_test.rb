# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/daily_report"

# rpms-rpc#365: parse Minitest's summary and failure blocks from captured stdout.
class RpmsRpc::DailyReport::MinitestOutputTest < Minitest::Test
  PASSING = <<~OUT
    Run options: --seed 1

    Finished in 0.001234s, 809.7164 runs/s, 3238.8656 assertions/s.

    10 runs, 40 assertions, 0 failures, 0 errors, 0 skips
  OUT

  MIXED = <<~OUT
    Run options: --seed 2

    Finished in 1.5s, 2.0 runs/s, 4.0 assertions/s.

     5 runs, 10 assertions, 1 failures, 1 errors, 2 skips

    Failure:
    AlphaTest#test_one:
    expected true

    Error:
    BetaTest#test_two:
    NoMethodError: undefined method

    Skipped:
    GammaTest#test_three:
    rpms-rpc#365: not ready yet

    Skipped:
    DeltaTest#test_four:
    tracked as #366

    Skipped:
    EpsilonTest#test_five:
    lakeraven/rpms-ops#834 waiting on wire cases
  OUT

  def test_passing_run_parses_counts_and_passed
    summary = RpmsRpc::DailyReport::MinitestOutput.parse(PASSING)

    refute summary.errored?
    assert summary.ok?
    assert_equal 10, summary.runs
    assert_equal 40, summary.assertions
    assert_equal 0, summary.failures
    assert_equal 0, summary.errors
    assert_equal 0, summary.skips
    assert_equal 10, summary.passed
    assert_empty summary.first_failures
    assert_empty summary.skip_issues
  end

  def test_mixed_run_collects_failures_skip_issues_and_passed
    summary = RpmsRpc::DailyReport::MinitestOutput.parse(MIXED)

    refute summary.errored?
    refute summary.ok?
    assert_equal 5, summary.runs
    assert_equal 1, summary.passed
    assert_equal [ "AlphaTest#test_one" ], summary.first_failures.take(1)
    assert_includes summary.first_failures, "BetaTest#test_two"
    assert_operator summary.first_failures.size, :<=, 5
    assert_equal [ "#365", "#366", "lakeraven/rpms-ops#834" ].sort, summary.skip_issues.sort
  end

  def test_output_without_summary_line_is_errored_not_passed
    summary = RpmsRpc::DailyReport::MinitestOutput.parse("something went wrong before minitest finished\n")

    assert summary.errored?
    refute summary.ok?
    assert_nil summary.runs
    assert_empty summary.first_failures
  end
end
