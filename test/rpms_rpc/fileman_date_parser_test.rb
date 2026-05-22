# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/fileman_date_parser"

class RpmsRpc::FilemanDateParserTest < Minitest::Test
  P = RpmsRpc::FilemanDateParser

  # -- parse_date -------------------------------------------------------------

  def test_parse_date_basic
    assert_equal Date.new(1980, 1, 1), P.parse_date("2800101")
  end

  def test_parse_date_2025
    assert_equal Date.new(2025, 1, 1), P.parse_date("3250101")
  end

  def test_parse_date_strips_time_part
    assert_equal Date.new(2025, 1, 1), P.parse_date("3250101.0915")
  end

  def test_parse_date_returns_nil_for_nil
    assert_nil P.parse_date(nil)
  end

  def test_parse_date_returns_nil_for_empty
    assert_nil P.parse_date("")
  end

  def test_parse_date_returns_nil_for_invalid_month
    assert_nil P.parse_date("3251301") # month 13
  end

  def test_parse_date_returns_nil_for_invalid_day
    assert_nil P.parse_date("3250230") # Feb 30
  end

  def test_parse_date_returns_nil_for_wrong_length
    assert_nil P.parse_date("325101") # 6 digits
  end

  # -- parse_datetime ---------------------------------------------------------

  def test_parse_datetime_with_hhmm
    result = P.parse_datetime("3250101.0915")
    assert_equal 2025, result.year
    assert_equal 1, result.month
    assert_equal 1, result.day
    assert_equal 9, result.hour
    assert_equal 15, result.min
  end

  def test_parse_datetime_with_hh_only
    result = P.parse_datetime("3250101.09")
    assert_equal 9, result.hour
    assert_equal 0, result.min
  end

  def test_parse_datetime_returns_nil_without_time_part
    assert_nil P.parse_datetime("3250101")
  end

  def test_parse_datetime_returns_nil_for_invalid_hour
    assert_nil P.parse_datetime("3250101.2500")
  end

  def test_parse_datetime_with_seconds
    result = P.parse_datetime("3250101.091533")
    assert_equal 2025, result.year
    assert_equal 9, result.hour
    assert_equal 15, result.min
    assert_equal 33, result.sec
  end

  def test_parse_datetime_returns_nil_for_invalid_seconds
    assert_nil P.parse_datetime("3250101.091560")
  end

  def test_parse_datetime_returns_nil_for_unsupported_length
    assert_nil P.parse_datetime("3250101.09153")
    assert_nil P.parse_datetime("3250101.0915334")
  end

  # -- format_datetime with seconds ------------------------------------------

  def test_format_datetime_with_seconds_true_emits_six_digit_time
    t = Time.new(2025, 1, 1, 9, 15, 33)
    assert_equal "3250101.091533", P.format_datetime(t, seconds: true)
  end

  def test_format_datetime_seconds_round_trips_through_parse
    t = Time.new(2025, 6, 15, 14, 30, 42)
    formatted = P.format_datetime(t, seconds: true)
    parsed = P.parse_datetime(formatted)
    assert_equal t.sec, parsed.sec, "seconds should survive round-trip"
  end

  # -- format_date ------------------------------------------------------------

  def test_format_date_basic
    assert_equal "3250101", P.format_date(Date.new(2025, 1, 1))
  end

  def test_format_date_pads_month_and_day
    assert_equal "3250105", P.format_date(Date.new(2025, 1, 5))
  end

  def test_format_date_returns_nil_for_nil
    assert_nil P.format_date(nil)
  end

  # -- format_datetime --------------------------------------------------------

  def test_format_datetime_basic
    t = Time.new(2025, 1, 1, 9, 15, 0)
    assert_equal "3250101.0915", P.format_datetime(t)
  end

  def test_round_trip
    t = Time.new(2025, 6, 15, 14, 30, 0)
    formatted = P.format_datetime(t)
    parsed = P.parse_datetime(formatted)
    assert_equal t.year, parsed.year
    assert_equal t.month, parsed.month
    assert_equal t.day, parsed.day
    assert_equal t.hour, parsed.hour
    assert_equal t.min, parsed.min
  end
end
