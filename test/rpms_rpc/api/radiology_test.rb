# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/radiology"

class RadiologyTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      # ORWRA REPORT LIST — multi-line
      m.seed_keyed_collection(:radiology_list, "8791", [
        { ien: 501, exam_name: "CHEST X-RAY",       cpt_code: "71045", status: "final",
          exam_date: nil, report_date: nil, radiologist_duz: "2843",
          radiologist_name: "SEVEN,HENRY L MD", impression: "No acute findings.",
          imaging_study_ien: 9001 },
        { ien: 502, exam_name: "CT ABDOMEN",        cpt_code: "74176", status: "final",
          exam_date: nil, report_date: nil, radiologist_duz: "2843",
          radiologist_name: "SEVEN,HENRY L MD", impression: "Possible mass; recommend follow-up.",
          imaging_study_ien: 9002 }
      ])

      # ORWRA REPORT — text blob keyed by report IEN
      m.seed_text(:radiology_report, "501",
        "EXAM: CHEST X-RAY\nIMPRESSION: No acute cardiopulmonary process.\nRADIOLOGIST: SEVEN,HENRY L MD")
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # === for_patient ===

  def test_for_patient_returns_radiology_reports
    reports = RpmsRpc::Radiology.for_patient(8791)
    assert_kind_of Array, reports
    assert_equal 2, reports.length

    chest = reports.find { |r| r[:exam_name] == "CHEST X-RAY" }
    refute_nil chest
    assert_equal "71045",                  chest[:cpt_code]
    assert_equal "final",                  chest[:status]
    assert_equal "SEVEN,HENRY L MD",       chest[:radiologist_name]
    assert_equal "No acute findings.",     chest[:impression]
    assert_equal 9001,                     chest[:imaging_study_ien]
  end

  def test_for_patient_returns_empty_for_invalid_dfn
    assert_equal [], RpmsRpc::Radiology.for_patient(nil)
    assert_equal [], RpmsRpc::Radiology.for_patient("")
    assert_equal [], RpmsRpc::Radiology.for_patient(0)
  end

  def test_for_patient_returns_empty_for_unknown_dfn
    assert_equal [], RpmsRpc::Radiology.for_patient(999999)
  end

  # === find ===

  def test_find_returns_report_text_by_ien
    text = RpmsRpc::Radiology.find(501)
    refute_nil text
    assert_match(/CHEST X-RAY/, text)
    assert_match(/IMPRESSION/, text)
    assert_match(/SEVEN,HENRY L MD/, text)
  end

  def test_find_returns_nil_for_invalid_ien
    assert_nil RpmsRpc::Radiology.find(nil)
    assert_nil RpmsRpc::Radiology.find("")
  end

  def test_find_returns_nil_for_unknown_ien
    assert_nil RpmsRpc::Radiology.find(999999)
  end

  # === Symbolic API contract ===

  def test_module_exposes_documented_methods
    assert RpmsRpc::Radiology.respond_to?(:for_patient)
    assert RpmsRpc::Radiology.respond_to?(:find)
  end
end
