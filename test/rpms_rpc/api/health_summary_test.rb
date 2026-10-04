# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/health_summary"

class HealthSummaryApiTest < Minitest::Test
  DFN = 8791

  def setup
    RpmsRpc.mock! do |m|
      # ORWRP REPORT TEXT is keyed by its first formal, the DFN (#259); one
      # summary serves for_patient and component_data alike.
      m.seed_text(:report_text, DFN.to_s,
        "PATIENT: Test Patient\n" \
        "DOB: 01/01/1970\n" \
        "PROBLEMS:\n" \
        "Type 2 diabetes\n" \
        "MEDICATIONS:\n" \
        "Metformin 500mg twice daily")

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
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_for_patient_generates_summary_sections
    summary = RpmsRpc::HealthSummary.for_patient(DFN)

    assert_equal "STANDARD", summary[:type]
    # Gateway behavior: only header sections that subsequently accumulate
    # body content get retained. "PATIENT: Test Patient" / "DOB: ..." are
    # header-only and produce no section because the next line is also a
    # header. Only PROBLEMS and MEDICATIONS pick up body content.
    assert_equal 2, summary[:sections].length
    assert_equal "Problems", summary[:sections].first[:name]
    assert_equal "Medications", summary[:sections].last[:name]
    assert_includes summary[:raw_content], "Type 2 diabetes"
  end

  def test_for_patient_uses_report_text_mapping_rpc_name
    RpmsRpc::HealthSummary.for_patient(DFN)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWRP REPORT TEXT" }
    refute_nil call
    # RPT(ROOT,DFN,RPTID,HSTYPE,DTRANGE,EXAMID,ALPHA,OMEGA) (ORWRP.m:88):
    # report 1 is the Health Summary, HSTYPE the resolved type IEN (#259).
    assert_equal [ DFN.to_s, "1", "1", "", "", "", "" ], call[:params]
  end

  def test_for_patient_resolves_the_summary_type_against_the_default_types
    RpmsRpc.reset!
    RpmsRpc.mock! do |m|
      m.seed_text(:report_text, DFN.to_s, "PROBLEMS:\nHypertension")
    end

    summary = RpmsRpc::HealthSummary.for_patient(DFN, summary_type: "brief")

    assert_equal "BRIEF", summary[:type]
    # RPT^ORWRP's formals (#259): DFN, the Health Summary report id, then the
    # resolved type's IEN (BRIEF = 2 in DEFAULT_TYPES); the rest empty.
    assert_equal [ DFN.to_s, "1", "2", "", "", "", "" ],
                 RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWRP REPORT TEXT" }[:params]
  end

  def test_for_patient_falls_back_to_the_first_default_type_for_an_unknown_name
    summary = RpmsRpc::HealthSummary.for_patient(DFN, summary_type: "NO SUCH TYPE")

    assert_equal "STANDARD", summary[:type]
  end

  def test_for_patient_skips_separator_only_lines_per_gateway
    RpmsRpc.reset!
    RpmsRpc.mock! do |m|
      m.seed_text(:report_text, DFN.to_s,
        "===============\n" \
        "PROBLEMS:\n" \
        "---------------\n" \
        "Hypertension\n" \
        "***************\n" \
        "MEDICATIONS:\n" \
        "Lisinopril 10mg")
    end

    summary = RpmsRpc::HealthSummary.for_patient(DFN)
    section_names = summary[:sections].map { |s| s[:name] }

    # Separator-only lines (===, ---, ***) match the header regex but are
    # then skipped entirely — they neither start new sections nor leak
    # `[-=*]+` into existing content.
    assert_includes section_names, "Problems"
    assert_includes section_names, "Medications"
    problems = summary[:sections].find { |s| s[:name] == "Problems" }
    refute_match(/[-=*]{3,}/, problems[:content],
      "separator lines should be skipped entirely, not appear in section content")
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

  def test_component_data_fetches_standard_component
    component = RpmsRpc::HealthSummary.component_data(DFN, :medications)

    refute_nil component
    assert_equal "MED", component[:code]
    assert_equal "Medications", component[:name]
    assert_includes component[:content], "Metformin"
    refute_includes component[:content], "Type 2 diabetes", "only the component's own section"
  end

  def test_component_data_returns_nil_when_the_summary_has_no_such_section
    assert_nil RpmsRpc::HealthSummary.component_data(DFN, :allergies)
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

  def test_module_exposes_standard_component_types
    assert_equal "DEM", RpmsRpc::HealthSummary::COMPONENT_TYPES[:demographics]
    assert_equal "PRB", RpmsRpc::HealthSummary::COMPONENT_TYPES[:problems]
    assert_equal "IMM", RpmsRpc::HealthSummary::COMPONENT_TYPES[:immunizations]
  end
end
