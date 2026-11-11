# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/health_summary"
require_relative "../captured_replies"

# HealthSummary's summary reads. The replies are the build's
# (test/fixtures/captured_replies/health-summary.yml): run as PROFILE,MD on
# demo patient DFN 4 on a throwaway container, recorded as flows and replayed
# through CiaClient. The live spec is test/live/health_summary_live_test.rb.
class HealthSummaryApiTest < Minitest::Test
  SLUG = "health-summary"
  DFN = 4
  HS = RpmsRpc::HealthSummary

  def teardown
    RpmsRpc.reset!
  end

  def replay(script = {})
    @client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = @client }
    @client
  end

  def replay_flow(name) = replay(CapturedReplies.flow_script(SLUG, name))

  # A flow's replies, each answered as often as the code under test asks.
  def replay_flow_repeatedly(name, times)
    replay(CapturedReplies.flow_script(SLUG, name).transform_values { |replies| replies * times })
  end

  def sent = @client.calls.map { |c| [ c[:rpc], c[:params] ] }

  def test_summary_types_are_the_ihs_types_on_file
    replay_flow("summary_types")
    types = HS.summary_types

    assert_includes types, { ien: "7", name: "ADULT REGULAR" }
    assert_includes types, { ien: "55", name: "MEDICATIONS" }
    assert_equal types.map { |t| t[:name] }.sort, types.map { |t| t[:name] }, "in name order, the B index"
    assert(types.all? { |t| t[:ien].match?(/\A\d+\z/) }, types.inspect)
  end

  # Report "IHS" runs HS^ORWRPBHS with HSTYPE as an IHS type (#9001015):
  # ADULT REGULAR is IEN 7 on the pinned build (#662).
  def test_for_patient_sends_the_ihs_report_with_the_listed_type
    replay_flow("for_patient")
    summary = HS.for_patient(DFN)

    assert_equal CapturedReplies.flow_calls(SLUG, "for_patient"), sent
    assert_equal [ "4", "IHS", "7", "", "", "", "" ], sent.last.last
    assert_equal "ADULT REGULAR", summary[:type]
    assert_nil summary[:error]
  end

  def test_for_patient_reads_the_reports_section_banners
    replay_flow("for_patient")
    names = HS.for_patient(DFN)[:sections].map { |s| s[:name] }

    assert_equal "DEMOGRAPHIC DATA", names.first
    assert_includes names, "ACTIVE PROBLEMS (ALL)"
    assert_includes names, "IMMUNIZATIONS"
    assert_equal names.uniq, names, "a section that runs onto the next page is one section"
  end

  def test_for_patient_drops_the_page_banners_and_keeps_the_sections_text
    replay_flow("for_patient")
    summary = HS.for_patient(DFN)
    problems = summary[:sections].find { |s| s[:name] == "ACTIVE PROBLEMS (ALL)" }

    assert_includes problems[:content], "Type 2 diabetes mellitus"
    refute(summary[:sections].any? { |s| s[:content].include?("CONFIDENTIAL PATIENT INFORMATION") }, "page banners are dropped")
    assert_includes summary[:raw_content], "(ADULT REGULAR SUMMARY)"
  end

  def test_for_patient_takes_a_type_by_ien
    replay_flow("for_patient_by_ien")
    summary = HS.for_patient(DFN, summary_type: 55)

    assert_equal CapturedReplies.flow_calls(SLUG, "for_patient_by_ien"), sent
    assert_equal "MEDICATIONS", summary[:type]
  end

  def test_for_patient_takes_a_type_name_in_any_case
    replay_flow("for_patient")

    assert_equal "ADULT REGULAR", HS.for_patient(DFN, summary_type: "adult regular")[:type]
    assert_equal [ "4", "IHS", "7", "", "", "", "" ], sent.last.last
  end

  def test_for_patient_sends_no_report_for_a_type_not_on_file
    replay_flow("summary_types")
    summary = HS.for_patient(DFN, summary_type: "STANDARD")

    assert_equal "ERROR", summary[:type]
    assert_equal "Unknown health summary type: STANDARD", summary[:error]
    assert_equal [ "DDR LISTER" ], @client.rpcs_called
  end

  # The fault HSX^ORWRPBHS prints for a type that is not in #9001015, read
  # as an error summary rather than as a report.
  def test_a_report_that_faulted_is_an_error_summary
    replay("DDR LISTER" => [ CapturedReplies.flow(SLUG, "summary_types").first.fetch("raw_return") ],
           "ORWRP REPORT TEXT" => [ CapturedReplies.raw(SLUG, "ihs_type_not_on_file") ])
    summary = HS.for_patient(DFN, summary_type: 7)

    assert_equal "ERROR", summary[:type]
    assert_equal "The server could not generate the ADULT REGULAR health summary", summary[:error]
  end

  # What the gem sent before #662: report 1 reads HSTYPE as a VA type, and
  # VA type 1 faults. The capture keeps it so the frame is not sent again.
  def test_the_old_frame_faults_on_the_build
    replay("ORWRP REPORT TEXT" => [ CapturedReplies.raw(SLUG, "report_1_type_1") ])

    assert_raises(RpmsRpc::Client::RpcMError) { HS.send(:report_text, DFN, "1", hs_type: "1") }
  end

  def test_for_patient_rejects_blank_zero_and_negative_dfn_without_a_call
    replay
    [ nil, "", 0, -1 ].each do |dfn|
      assert_equal "Invalid patient DFN", HS.for_patient(dfn)[:error], dfn.inspect
    end
    assert_empty @client.calls
  end

  def test_component_data_picks_the_components_section_out_of_the_summary
    replay_flow("for_patient")
    component = HS.component_data(DFN, :problems)

    assert_equal [ "Problems", "PRB" ], component.values_at(:name, :code)
    assert_includes component[:content], "Type 2 diabetes mellitus"
    refute_includes component[:content], "IMMUNIZATION FORECAST", "only the component's own section"
  end

  # A heading of 74 or more characters prints with no dashes (BREAK^APCHS0):
  # " SCHEDULED ENCOUNTERS (...) (max 10 visits or 90 days) " is a section of
  # its own, so the medications end where it starts.
  def test_a_banner_too_long_for_dashes_opens_its_own_section
    replay_flow("for_patient")
    summary = HS.for_patient(DFN)
    medications = summary[:sections].find { |s| s[:name].start_with?("CURRENT MEDICATIONS") }

    assert_includes summary[:sections].map { |s| s[:name] },
                    "SCHEDULED ENCOUNTERS (INCLUDES CHART REQ AND WALK INS) (max 10 visits or 90 days)"
    refute_includes medications[:content], "SCHEDULED ENCOUNTERS"
  end

  # Components whose IHS headings are other words than their names.
  def test_component_data_finds_components_under_their_ihs_headings
    replay_flow_repeatedly("for_patient", 3)

    assert_includes HS.component_data(DFN, :demographics)[:content], "DOB:"
    assert_includes HS.component_data(DFN, :vitals)[:content], "117/81"
    refute_includes HS.component_data(DFN, :medications)[:content], "SCHEDULED ENCOUNTERS"
  end

  def test_component_data_is_nil_when_the_summary_has_no_such_section
    replay_flow("for_patient")

    assert_nil HS.component_data(DFN, :radiology)
  end

  def test_component_data_returns_nil_for_invalid_component_or_dfn
    replay
    assert_nil HS.component_data(DFN, :unknown)
    assert_nil HS.component_data(0, :medications)
    assert_empty @client.calls
  end

  def test_generate_selective_returns_only_requested_components
    replay_flow_repeatedly("for_patient", 2)
    summary = HS.generate_selective(DFN, components: [ :immunizations, :unknown, :problems ])

    assert_equal "SELECTIVE", summary[:type]
    assert_equal %w[IMM PRB], summary[:sections].map { |s| s[:code] }
  end

  def test_module_exposes_standard_component_types
    assert_equal "DEM", HS::COMPONENT_TYPES[:demographics]
    assert_equal "PRB", HS::COMPONENT_TYPES[:problems]
    assert_equal "IMM", HS::COMPONENT_TYPES[:immunizations]
  end
end
