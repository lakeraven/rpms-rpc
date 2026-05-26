# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/lab"

class LabTest < Minitest::Test
  DFN = 8791

  def setup
    list_key = RpmsRpc::Lab.build_list_param(DFN)

    RpmsRpc.mock! do |m|
      # ORWLRR RESULT LIST — single composite param "dfn^from^to".
      # Format per line: IEN^TEST_NAME^RESULT^UNITS^REF_RANGE^ABNORMAL_FLAG^COLLECTION_DATE^STATUS
      m.seed_keyed_collection(:lab_result_list, list_key, [
        { ien: 101, test_name: "GLUCOSE",        result: "95",  units: "mg/dL",  reference_range: "70-100", abnormal_flag: "N", collection_date: nil, status: "final" },
        { ien: 102, test_name: "HEMOGLOBIN A1C", result: "7.2", units: "%",      reference_range: "<5.7",   abnormal_flag: "H", collection_date: nil, status: "final" },
        { ien: 103, test_name: "CHOLESTEROL",    result: "210", units: "mg/dL",  reference_range: "<200",   abnormal_flag: "H", collection_date: nil, status: "final" }
      ])

      # ORWLRR REPORT LIST — 10-field aggregated panels (gateway shape).
      m.seed_keyed_collection(:lab_report_list, DFN.to_s, [
        {
          ien: 201, report_name: "BASIC METABOLIC PANEL", loinc_code: "24323-8",
          status: "final", collection_date: nil, result_date: nil,
          verifier_duz: "301", verifier_name: "SEVEN,HENRY L",
          result_iens: "1001;1002;1003", interpretation: nil
        },
        {
          ien: 202, report_name: "LIPID PANEL", loinc_code: "57698-3",
          status: "",  # API should default to "final"
          collection_date: nil, result_date: nil,
          verifier_duz: "301", verifier_name: "SEVEN,HENRY L",
          result_iens: "1010;1011", interpretation: nil
        }
      ])

      # ORWLRR REPORT — single composite key "dfn^lab_ien", text blob with
      # LABEL: VALUE lines plus component lines.
      m.seed_text(:lab_report, "#{DFN}^201",
        "TEST: BASIC METABOLIC PANEL\n" \
        "RESULT: see components\n" \
        "COLLECTED: 3260514.0900\n" \
        "STATUS: final\n" \
        "ORDERING PROVIDER: SEVEN,HENRY L\n" \
        "PERFORMING LAB: Reference Lab\n" \
        "SODIUM^140^mmol/L^135-145^N\n" \
        "POTASSIUM^5.8^mmol/L^3.5-5.0^H\n" \
        "GLUCOSE^88^mg/dL^70-100^N")

      # Single-test detail (no components) — derives :abnormal from
      # the abnormal_flag label.
      m.seed_text(:lab_report, "#{DFN}^202",
        "TEST: GLUCOSE\n" \
        "RESULT: 250\n" \
        "UNITS: mg/dL\n" \
        "REFERENCE RANGE: 70-100\n" \
        "ABNORMAL FLAG: H\n" \
        "STATUS: final")
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # === for_patient — recent lab list ============================================

  def test_for_patient_sends_caret_delimited_dfn_from_to_composite
    RpmsRpc::Lab.for_patient(DFN)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWLRR RESULT LIST" }
    refute_nil call
    assert_equal 1, call[:params].length, "ORWLRR RESULT LIST takes a single composite param"
    assert_equal RpmsRpc::Lab.build_list_param(DFN), call[:params].first
    parts = call[:params].first.split("^")
    assert_equal "8791",  parts[0]
    assert_match %r{\A\d{2}/\d{2}/\d{4}\z}, parts[1]
    assert_match %r{\A\d{2}/\d{2}/\d{4}\z}, parts[2]
  end

  def test_for_patient_returns_recent_lab_results
    results = RpmsRpc::Lab.for_patient(DFN)

    assert_kind_of Array, results
    assert_equal 3, results.length
    glucose = results.find { |r| r[:test_name] == "GLUCOSE" }
    refute_nil glucose
    assert_equal "95",    glucose[:result]
    assert_equal "mg/dL", glucose[:units]
  end

  def test_for_patient_marks_abnormal_when_flag_is_not_N
    results = RpmsRpc::Lab.for_patient(DFN)
    a1c = results.find { |r| r[:test_name] == "HEMOGLOBIN A1C" }
    assert_equal true, a1c[:abnormal]
    assert_equal "H",  a1c[:abnormal_flag]
  end

  def test_for_patient_marks_normal_when_flag_is_N
    results = RpmsRpc::Lab.for_patient(DFN)
    glucose = results.find { |r| r[:test_name] == "GLUCOSE" }
    assert_equal false, glucose[:abnormal]
  end

  def test_for_patient_returns_empty_for_invalid_dfn
    assert_equal [], RpmsRpc::Lab.for_patient(nil)
    assert_equal [], RpmsRpc::Lab.for_patient("")
    assert_equal [], RpmsRpc::Lab.for_patient(0)
  end

  def test_for_patient_returns_empty_for_unknown_dfn
    assert_equal [], RpmsRpc::Lab.for_patient(999_999)
  end

  # === abnormal filter ==========================================================

  def test_abnormal_returns_only_abnormal_results
    abnormal = RpmsRpc::Lab.abnormal(DFN)
    assert_equal 2, abnormal.length
    assert(abnormal.all? { |r| r[:abnormal] })
    names = abnormal.map { |r| r[:test_name] }.sort
    assert_equal [ "CHOLESTEROL", "HEMOGLOBIN A1C" ], names
  end

  # === reports — DiagnosticReport-style list ====================================

  def test_reports_returns_diagnostic_report_panels_with_gateway_field_names
    reports = RpmsRpc::Lab.reports(DFN)

    assert_kind_of Array, reports
    assert_equal 2, reports.length
    bmp = reports.find { |r| r[:report_name] == "BASIC METABOLIC PANEL" }
    refute_nil bmp
    assert_equal "24323-8",           bmp[:loinc_code]
    assert_equal "final",             bmp[:status]
    assert_equal "SEVEN,HENRY L",     bmp[:verifier_name]
    assert_equal "301",               bmp[:verifier_duz]
    assert_equal "1001;1002;1003",    bmp[:result_iens]
  end

  def test_reports_defaults_blank_status_to_final
    reports = RpmsRpc::Lab.reports(DFN)
    lipid = reports.find { |r| r[:report_name] == "LIPID PANEL" }
    assert_equal "final", lipid[:status]
  end

  def test_reports_returns_empty_for_invalid_dfn
    assert_equal [], RpmsRpc::Lab.reports(nil)
    assert_equal [], RpmsRpc::Lab.reports("")
    assert_equal [], RpmsRpc::Lab.reports(0)
  end

  # === find — single lab detail =================================================

  def test_find_sends_caret_delimited_dfn_lab_ien_composite
    RpmsRpc::Lab.find(DFN, 201)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWLRR REPORT" }
    refute_nil call
    assert_equal 1, call[:params].length, "ORWLRR REPORT takes a single composite param"
    assert_equal "#{DFN}^201", call[:params].first
  end

  def test_find_returns_lab_detail_by_ien
    detail = RpmsRpc::Lab.find(DFN, 201)

    refute_nil detail
    assert_equal 201,                      detail[:ien]
    assert_equal "BASIC METABOLIC PANEL",  detail[:test_name]
    assert_equal "see components",         detail[:result]
    assert_equal "final",                  detail[:status]
    assert_equal "SEVEN,HENRY L",          detail[:ordering_provider]
    assert_equal "Reference Lab",          detail[:performing_lab]
  end

  def test_find_parses_panel_components_from_caret_lines
    detail = RpmsRpc::Lab.find(DFN, 201)

    assert_kind_of Array, detail[:components]
    assert_equal 3, detail[:components].length
    sodium = detail[:components].find { |c| c[:name] == "SODIUM" }
    refute_nil sodium
    assert_equal "140",     sodium[:result]
    assert_equal "mmol/L",  sodium[:units]
    assert_equal "135-145", sodium[:reference_range]
    assert_equal false,     sodium[:abnormal]
    assert_equal "N",       sodium[:abnormal_flag]

    potassium = detail[:components].find { |c| c[:name] == "POTASSIUM" }
    assert_equal true,      potassium[:abnormal]
    assert_equal "H",       potassium[:abnormal_flag]
  end

  def test_find_derives_overall_abnormal_from_any_abnormal_component
    detail = RpmsRpc::Lab.find(DFN, 201)
    assert_equal true, detail[:abnormal],
      "panel-level :abnormal should be true when any component is abnormal"
  end

  def test_find_falls_back_to_abnormal_flag_when_no_components
    detail = RpmsRpc::Lab.find(DFN, 202)
    assert_empty detail[:components]
    assert_equal "H",  detail[:abnormal_flag]
    assert_equal true, detail[:abnormal]
  end

  def test_find_returns_nil_for_invalid_dfn
    assert_nil RpmsRpc::Lab.find(nil, 201)
    assert_nil RpmsRpc::Lab.find("", 201)
  end

  def test_find_returns_nil_for_invalid_ien
    assert_nil RpmsRpc::Lab.find(DFN, nil)
    assert_nil RpmsRpc::Lab.find(DFN, "")
  end

  def test_find_returns_nil_for_unknown_combination
    assert_nil RpmsRpc::Lab.find(DFN, 999_999)
  end

  # === Symbolic API contract ====================================================

  def test_module_exposes_documented_methods
    assert RpmsRpc::Lab.respond_to?(:for_patient)
    assert RpmsRpc::Lab.respond_to?(:abnormal)
    assert RpmsRpc::Lab.respond_to?(:reports)
    assert RpmsRpc::Lab.respond_to?(:find)
    assert RpmsRpc::Lab.respond_to?(:build_list_param)
  end
end
