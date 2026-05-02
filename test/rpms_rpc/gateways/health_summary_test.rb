# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"

# Tests for health summary RPCs via text_blob mappings.
class HealthSummaryTest < Minitest::Test
  def setup
    summary = <<~TEXT
      HEALTH SUMMARY - STANDARD
      ==========================
      Patient: DOE,JOHN
      DOB: 01/15/1980

      ALLERGIES:
        Penicillin - Hives
        Shellfish - Anaphylaxis

      MEDICATIONS:
        Lisinopril 10mg - 1 tab daily
        Metformin 500mg - 1 tab BID
    TEXT

    RpmsRpc.mock! do |m|
      m.seed(:health_summary_report, "1", summary.strip)
      m.seed(:health_summary_report, "2", "HEALTH SUMMARY - STANDARD\n==========================\nNo data available")
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # =============================================================================
  # HEALTH SUMMARY REPORT (text_blob)
  # =============================================================================

  def test_fetch_health_summary_returns_full_text
    text = RpmsRpc::DataMapper.health_summary_report.fetch_text("1")

    refute_nil text
    assert_includes text, "HEALTH SUMMARY"
    assert_includes text, "DOE,JOHN"
  end

  def test_fetch_health_summary_includes_allergies
    text = RpmsRpc::DataMapper.health_summary_report.fetch_text("1")

    assert_includes text, "ALLERGIES"
    assert_includes text, "Penicillin"
  end

  def test_fetch_health_summary_includes_medications
    text = RpmsRpc::DataMapper.health_summary_report.fetch_text("1")

    assert_includes text, "MEDICATIONS"
    assert_includes text, "Lisinopril"
  end

  def test_fetch_health_summary_for_patient_with_no_data
    text = RpmsRpc::DataMapper.health_summary_report.fetch_text("2")

    assert_includes text, "No data available"
  end

  def test_fetch_health_summary_returns_nil_for_unknown_patient
    assert_nil RpmsRpc::DataMapper.health_summary_report.fetch_text("99999")
  end

  def test_health_summary_preserves_line_structure
    text = RpmsRpc::DataMapper.health_summary_report.fetch_text("1")

    lines = text.split("\n")
    assert lines.length > 5, "Expected multiline health summary"
  end
end
