# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/lab"

class LabTest < Minitest::Test
  DFN = 8791
  OTHER_DFN = 18_791

  def setup
    recent = DateTime.now - 3

    RpmsRpc.mock! do |m|
      # Structured labs come from the CPRS graphing RPC pair:
      # ORWGRPC ITEMS (DFN, "63") enumerates the patient's lab tests, then
      # ORWGRPC ITEMDATA ("63^<test ien>", START, DFN) returns datapoints.
      # ITEMDATA is keyed by its FIRST param — the item, not the DFN.
      m.seed_keyed_collection(:lab_graph_items, DFN.to_s, [
        { file_number: "63", test_ien: 101, test_name: "GLUCOSE",        newest_result: recent },
        { file_number: "63", test_ien: 102, test_name: "HEMOGLOBIN A1C", newest_result: recent },
        { file_number: "63", test_ien: 103, test_name: "CHOLESTEROL",    newest_result: recent }
      ])
      m.seed_keyed_collection(:lab_graph_data, "63^101", [
        { file_number: "63", test_ien: 101, collection_date: recent, result: "95",
          abnormal_flag: "N", specimen_code: "70", specimen: "BLOOD",
          reference_range: "70!100", units: "mg/dL" }
      ])
      m.seed_keyed_collection(:lab_graph_data, "63^102", [
        { file_number: "63", test_ien: 102, collection_date: recent, result: "7.2",
          abnormal_flag: "H", specimen_code: "70", specimen: "BLOOD",
          reference_range: "", units: "%" }
      ])
      m.seed_keyed_collection(:lab_graph_data, "63^103", [
        { file_number: "63", test_ien: 103, collection_date: recent, result: "210",
          abnormal_flag: "H", specimen_code: "70", specimen: "BLOOD",
          reference_range: "", units: "mg/dL" }
      ])

      # ORWLR REPORT LISTS — global report type catalog (no params).
      # Format: REPORT_ID^REPORT_NAME^ENABLED_FLAG^REQUIRES_DATE_FLAG^MAX_OCCURRENCES
      m.seed_collection(:lab_report_list, [
        { report_id: "BASIC METABOLIC PANEL", report_name: "Basic Metabolic Panel", enabled_flag: "Y", requires_date_flag: "N", max_occurrences: 80 },
        { report_id: "LIPID PANEL",           report_name: "Lipid Panel",           enabled_flag: "Y", requires_date_flag: "N", max_occurrences: 80 }
      ])

      # ORWRP REPORT TEXT — text blob keyed by DFN (first param).
      m.seed_text(:lab_report, DFN.to_s,
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
      m.seed_text(:lab_report, OTHER_DFN.to_s,
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

  def test_for_patient_uses_graphing_rpcs_on_the_wire
    RpmsRpc::Lab.for_patient(DFN)

    items_call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWGRPC ITEMS" }
    refute_nil items_call
    assert_equal [ "8791", "63" ], items_call[:params]

    data_call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWGRPC ITEMDATA" }
    refute_nil data_call
    assert_equal "63^101", data_call[:params][0]
    assert_match(/\A\d{7}\z/, data_call[:params][1], "START should be a FileMan date")
    assert_equal "8791", data_call[:params][2]
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

  def test_reports_returns_report_type_catalog_with_gateway_field_names
    reports = RpmsRpc::Lab.reports(DFN)

    assert_kind_of Array, reports
    assert_equal 2, reports.length
    bmp = reports.find { |r| r[:report_id] == "BASIC METABOLIC PANEL" }
    refute_nil bmp
    assert_equal "Basic Metabolic Panel", bmp[:report_name]
    assert_equal "Y",                     bmp[:enabled_flag]
    assert_equal "N",                     bmp[:requires_date_flag]
    assert_equal 80,                      bmp[:max_occurrences]
  end

  def test_reports_defaults_blank_status_to_final
    reports = RpmsRpc::Lab.reports(DFN)
    lipid = reports.find { |r| r[:report_id] == "LIPID PANEL" }
    assert_equal "final", lipid[:status]
  end

  def test_reports_returns_empty_for_invalid_dfn
    assert_equal [], RpmsRpc::Lab.reports(nil)
    assert_equal [], RpmsRpc::Lab.reports("")
    assert_equal [], RpmsRpc::Lab.reports(0)
  end

  # === find — single lab detail =================================================

  def test_find_sends_orwrp_report_text_params
    RpmsRpc::Lab.find(DFN, 201)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWRP REPORT TEXT" }
    refute_nil call
    assert_equal 7, call[:params].length, "ORWRP REPORT TEXT takes seven params"
    assert_equal "8791", call[:params][0]
    assert_equal "201",  call[:params][1]
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
    detail = RpmsRpc::Lab.find(OTHER_DFN, 202)
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
    assert_nil RpmsRpc::Lab.find(99_999, 999_999)
  end

  # === Symbolic API contract ====================================================

  def test_module_exposes_documented_methods
    assert RpmsRpc::Lab.respond_to?(:for_patient)
    assert RpmsRpc::Lab.respond_to?(:abnormal)
    assert RpmsRpc::Lab.respond_to?(:reports)
    assert RpmsRpc::Lab.respond_to?(:find)
    assert RpmsRpc::Lab.respond_to?(:build_list_param)
  end

  # === :orwlrr_lab_reports capability gating ===================================

  def test_for_patient_returns_empty_when_orwlrr_unsupported
    RpmsRpc.client.seed_capability(:orwlrr_lab_reports, supported: false)
    assert_equal [], RpmsRpc::Lab.for_patient(DFN)
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWLRR INTERIM" }
  end

  def test_reports_returns_empty_when_orwlrr_unsupported
    RpmsRpc.client.seed_capability(:orwlrr_lab_reports, supported: false)
    assert_equal [], RpmsRpc::Lab.reports(DFN)
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWLR REPORT LISTS" }
  end

  def test_find_returns_nil_when_orwlrr_unsupported
    RpmsRpc.client.seed_capability(:orwlrr_lab_reports, supported: false)
    assert_nil RpmsRpc::Lab.find(DFN, 501)
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWRP REPORT TEXT" }
  end
end
