# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/health_summary"

class HealthSummaryApiTest < Minitest::Test
  DFN = 8791

  def setup
    RpmsRpc.mock! do |m|
      m.seed_collection(:report_types, [
        { ien: 1, name: "STANDARD", description: "Standard Health Summary", owner: "SYSTEM" },
        { ien: 2, name: "BRIEF", description: "Brief Summary", owner: "SYSTEM" }
      ])

      m.seed_keyed_collection(:report_type_components, "1", [
        { ien: 10, name: "Demographics", abbreviation: "DEM", sequence: 1 },
        { ien: 11, name: "Problems", abbreviation: "PRB", sequence: 2 }
      ])

      m.seed_text(:report_text, "#{DFN}^1^",
        "PATIENT: Test Patient\n" \
        "DOB: 01/01/1970\n" \
        "PROBLEMS:\n" \
        "Type 2 diabetes\n" \
        "MEDICATIONS:\n" \
        "Metformin")

      m.seed_text(:report_text, "#{DFN}^^MED",
        "MEDICATIONS:\n" \
        "Metformin 500mg twice daily")

      m.seed_text(:health_summary_report, DFN.to_s,
        "WELLNESS GOALS\n" \
        "Walk 30 minutes daily\n" \
        "PREVENTIVE CARE\n" \
        "Influenza vaccine due")

      m.seed_keyed_collection(:reminders_list, DFN.to_s, [
        {
          ien: 501,
          name: "A1C Screening",
          status: "DUE",
          due_date: nil,
          last_done: nil,
          priority: "HIGH"
        }
      ])

      m.seed_text(:reminder_detail, "#{DFN}^501",
        "A1C Screening\n" \
        "Patient is due for hemoglobin A1C.")

      m.seed_keyed_collection(:maint_items, DFN.to_s, [
        {
          ien: 601,
          name: "Diabetes Eye Exam",
          category: "Preventive",
          status: "",
          last_done: nil,
          next_due: nil,
          frequency: "Yearly"
        }
      ])

      m.seed_collection(:flowsheet_list, [
        { ien: 701, name: "Diabetes Measures", description: "A1C and related measures" }
      ])

      m.seed_text(:flowsheet_data, "#{DFN}^701^01/01/2026^05/26/2026",
        "Date^A1C\n" \
        "05/01/2026^7.2")
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_for_patient_generates_summary_sections
    summary = RpmsRpc::HealthSummary.for_patient(DFN)

    assert_equal "STANDARD", summary[:type]
    assert_equal 4, summary[:sections].length
    assert_equal "Patient", summary[:sections].first[:name]
    assert_includes summary[:raw_content], "Type 2 diabetes"
  end

  def test_for_patient_uses_report_text_mapping_rpc_name
    RpmsRpc::HealthSummary.for_patient(DFN)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWRP REPORT TEXT" }
    refute_nil call
    assert_equal [ "#{DFN}^1^" ], call[:params]
  end

  def test_for_patient_rejects_blank_zero_negative_and_unknown_dfn
    assert_equal "ERROR", RpmsRpc::HealthSummary.for_patient(nil)[:type]
    assert_equal "ERROR", RpmsRpc::HealthSummary.for_patient("")[:type]
    assert_equal "ERROR", RpmsRpc::HealthSummary.for_patient(0)[:type]
    assert_equal "ERROR", RpmsRpc::HealthSummary.for_patient(-1)[:type]

    unknown = RpmsRpc::HealthSummary.for_patient(999_999)
    assert_equal "ERROR", unknown[:type]
    assert_equal "No data returned", unknown[:error]
  end

  def test_types_returns_gateway_field_positions
    type = RpmsRpc::HealthSummary.types.first

    assert_equal 1, type[:ien]
    assert_equal "STANDARD", type[:name]
    assert_equal "Standard Health Summary", type[:description]
    assert_equal "SYSTEM", type[:owner]
  end

  def test_type_components_returns_components_for_summary_type
    components = RpmsRpc::HealthSummary.type_components(1)

    assert_equal 2, components.length
    assert_equal "DEM", components.first[:abbreviation]
    assert_equal 1, components.first[:sequence]
  end

  def test_component_data_fetches_standard_component
    component = RpmsRpc::HealthSummary.component_data(DFN, :medications)

    refute_nil component
    assert_equal "MED", component[:code]
    assert_equal "Medications", component[:name]
    assert_includes component[:content], "Metformin"
  end

  def test_component_data_returns_nil_for_invalid_component_or_dfn
    assert_nil RpmsRpc::HealthSummary.component_data(DFN, :unknown)
    assert_nil RpmsRpc::HealthSummary.component_data(0, :medications)
  end

  def test_generate_selective_returns_only_requested_components
    summary = RpmsRpc::HealthSummary.generate_selective(DFN, components: [ :medications, :unknown ])

    assert_equal "SELECTIVE", summary[:type]
    assert_equal 1, summary[:sections].length
    assert_equal "MED", summary[:sections].first[:code]
  end

  def test_personal_wellness_report_parses_multiline_sections
    report = RpmsRpc::HealthSummary.personal_wellness_report(DFN)

    assert_includes report[:content], "WELLNESS GOALS"
    assert_equal 2, report[:sections].length
    assert_equal "Wellness Goals", report[:sections].first[:name]
    assert_equal [ "Walk 30 minutes daily" ], report[:sections].first[:items]
  end

  def test_clinical_reminders_returns_gateway_field_positions
    reminder = RpmsRpc::HealthSummary.clinical_reminders(DFN).first

    assert_equal 501, reminder[:ien]
    assert_equal "A1C Screening", reminder[:name]
    assert_equal "DUE", reminder[:status]
    assert_equal "HIGH", reminder[:priority]
  end

  def test_reminder_detail_returns_multiline_content
    detail = RpmsRpc::HealthSummary.reminder_detail(DFN, 501)

    refute_nil detail
    assert_includes detail[:content], "Patient is due"
  end

  def test_health_maintenance_normalizes_blank_status_to_nil
    item = RpmsRpc::HealthSummary.health_maintenance(DFN).first

    assert_equal 601, item[:ien]
    assert_equal "Diabetes Eye Exam", item[:name]
    assert_nil item[:status]
    assert_equal "Yearly", item[:frequency]
  end

  def test_health_maintenance_returns_empty_for_invalid_or_unknown_dfn
    assert_equal [], RpmsRpc::HealthSummary.health_maintenance(nil)
    assert_equal [], RpmsRpc::HealthSummary.health_maintenance("")
    assert_equal [], RpmsRpc::HealthSummary.health_maintenance(0)
    assert_equal [], RpmsRpc::HealthSummary.health_maintenance(-1)
    assert_equal [], RpmsRpc::HealthSummary.health_maintenance(999_999)
  end

  def test_flowsheet_definitions_returns_gateway_field_positions
    flow = RpmsRpc::HealthSummary.flowsheet_definitions.first

    assert_equal 701, flow[:ien]
    assert_equal "Diabetes Measures", flow[:name]
    assert_equal "A1C and related measures", flow[:description]
  end

  def test_flowsheet_uses_mapping_rpc_name_and_parses_table
    result = RpmsRpc::HealthSummary.flowsheet(
      DFN,
      flowsheet_ien: 701,
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 5, 26)
    )

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "GMTS FLOWSHEET DATA" }
    refute_nil call
    assert_equal [ "#{DFN}^701^01/01/2026^05/26/2026" ], call[:params]
    assert_equal [ "Date", "A1C" ], result[:headers]
    assert_equal "7.2", result[:items].first[:a1c]
  end

  def test_module_exposes_standard_component_types
    assert_equal "DEM", RpmsRpc::HealthSummary::COMPONENT_TYPES[:demographics]
    assert_equal "PRB", RpmsRpc::HealthSummary::COMPONENT_TYPES[:problems]
    assert_equal "IMM", RpmsRpc::HealthSummary::COMPONENT_TYPES[:immunizations]
  end
end
