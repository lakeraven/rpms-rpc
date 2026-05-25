# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/lab"

class LabTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      # ORWLRR RESULT LIST — multi-line; format:
      #   IEN^TEST_NAME^RESULT^UNITS^REF_RANGE^ABNORMAL_FLAG^COLLECTION_DATE^STATUS
      # Mock client keys on first param (the DFN^from^to composite).
      m.seed_keyed_collection(:lab_result_list, "8791", [
        { ien: 101, test_name: "GLUCOSE",        result: "95",  units: "mg/dL",  reference_range: "70-100", abnormal_flag: "N", collection_date: nil, status: "final" },
        { ien: 102, test_name: "HEMOGLOBIN A1C", result: "7.2", units: "%",      reference_range: "<5.7",   abnormal_flag: "H", collection_date: nil, status: "final" },
        { ien: 103, test_name: "CHOLESTEROL",    result: "210", units: "mg/dL",  reference_range: "<200",   abnormal_flag: "H", collection_date: nil, status: "final" }
      ])

      # ORWLRR REPORT LIST — DiagnosticReport-style aggregation
      m.seed_keyed_collection(:lab_report_list, "8791", [
        { ien: 201, panel_name: "BASIC METABOLIC PANEL", performed_at_raw: "3260514.0900", status: "final", performing_lab: "Reference Lab" },
        { ien: 202, panel_name: "LIPID PANEL",           performed_at_raw: "3260514.0930", status: "final", performing_lab: "Reference Lab" }
      ])

      # ORWLRR REPORT — text blob, label: value lines
      m.seed_text(:lab_report, "8791|201",
        "TEST: BASIC METABOLIC PANEL\nRESULT: see components\nCOLLECTED: 3260514.0900\nSTATUS: final\nORDERING PROVIDER: SEVEN,HENRY L\nPERFORMING LAB: Reference Lab")
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # === for_patient — recent lab list ===

  def test_for_patient_returns_recent_lab_results
    results = RpmsRpc::Lab.for_patient(8791)

    assert_kind_of Array, results
    assert_equal 3, results.length
    glucose = results.find { |r| r[:test_name] == "GLUCOSE" }
    refute_nil glucose
    assert_equal "95",  glucose[:result]
    assert_equal "mg/dL", glucose[:units]
  end

  def test_for_patient_marks_abnormal_when_flag_is_not_N
    results = RpmsRpc::Lab.for_patient(8791)
    a1c = results.find { |r| r[:test_name] == "HEMOGLOBIN A1C" }
    assert_equal true, a1c[:abnormal]
    assert_equal "H",  a1c[:abnormal_flag]
  end

  def test_for_patient_marks_normal_when_flag_is_N
    results = RpmsRpc::Lab.for_patient(8791)
    glucose = results.find { |r| r[:test_name] == "GLUCOSE" }
    assert_equal false, glucose[:abnormal]
  end

  def test_for_patient_returns_empty_for_invalid_dfn
    assert_equal [], RpmsRpc::Lab.for_patient(nil)
    assert_equal [], RpmsRpc::Lab.for_patient("")
    assert_equal [], RpmsRpc::Lab.for_patient(0)
  end

  def test_for_patient_returns_empty_for_unknown_dfn
    assert_equal [], RpmsRpc::Lab.for_patient(999999)
  end

  # === abnormal filter ===

  def test_abnormal_returns_only_abnormal_results
    abnormal = RpmsRpc::Lab.abnormal(8791)
    assert_equal 2, abnormal.length
    assert(abnormal.all? { |r| r[:abnormal] })
    abbreviations = abnormal.map { |r| r[:test_name] }.sort
    assert_equal [ "CHOLESTEROL", "HEMOGLOBIN A1C" ], abbreviations
  end

  # === reports — DiagnosticReport-style list ===

  def test_reports_returns_diagnostic_report_panels
    reports = RpmsRpc::Lab.reports(8791)

    assert_kind_of Array, reports
    assert_equal 2, reports.length
    bmp = reports.find { |r| r[:panel_name] == "BASIC METABOLIC PANEL" }
    refute_nil bmp
    assert_equal "final",         bmp[:status]
    assert_equal "Reference Lab", bmp[:performing_lab]
  end

  def test_reports_returns_empty_for_invalid_dfn
    assert_equal [], RpmsRpc::Lab.reports(nil)
  end

  # === find — single lab detail ===

  def test_find_returns_lab_detail_by_ien
    detail = RpmsRpc::Lab.find(8791, 201)

    refute_nil detail
    assert_equal "BASIC METABOLIC PANEL", detail[:test_name]
    assert_equal "see components",         detail[:result]
    assert_equal "final",                  detail[:status]
    assert_equal "SEVEN,HENRY L",          detail[:ordering_provider]
    assert_equal "Reference Lab",          detail[:performing_lab]
  end

  def test_find_returns_nil_for_invalid_dfn
    assert_nil RpmsRpc::Lab.find(nil, 201)
  end

  def test_find_returns_nil_for_invalid_ien
    assert_nil RpmsRpc::Lab.find(8791, nil)
  end

  def test_find_returns_nil_for_unknown_combination
    assert_nil RpmsRpc::Lab.find(8791, 999999)
  end

  # === Symbolic API contract ===

  def test_module_exposes_documented_methods
    assert RpmsRpc::Lab.respond_to?(:for_patient)
    assert RpmsRpc::Lab.respond_to?(:abnormal)
    assert RpmsRpc::Lab.respond_to?(:reports)
    assert RpmsRpc::Lab.respond_to?(:find)
  end
end
