# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/behavioral_health/encounters"
require "rpms_rpc/api/behavioral_health/reference"
require_relative "../../captured_replies"

# BehavioralHealth::Encounters and the Reference reads beside it, on the AMHG
# replies the demo image sent for its seeded BH records
# (test/fixtures/captured_replies/amhg-encounters.yml, recorded as flows as the
# BH provider), replayed through CiaClient's own GLOBAL ARRAY read. The round
# trip is test/live/behavioral_health_encounters_live_test.rb.
class BehavioralHealthEncountersTest < Minitest::Test
  E = RpmsRpc::BehavioralHealth::Encounters
  R = RpmsRpc::BehavioralHealth::Reference
  SLUG = "amhg-encounters"
  RANGE = { from: "3000101", to: "3271231" }.freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow)
    @client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(SLUG, flow))
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  # Every call of the flow went out under AMHGRPC, with the parameters recorded.
  def assert_sent(flow)
    sent = @client.calls.reject { |c| c[:rpc] == :create_context }
    assert_equal CapturedReplies.flow_calls(SLUG, flow), sent.map { |c| [ c[:rpc], c[:params] ] }
    assert_includes @client.calls, { rpc: :create_context, params: [ "AMHGRPC" ] }
  end

  def test_visit_list_reads_the_rows_and_who_signed
    replay("visit_list")
    visits = E.visit_list("990017", **RANGE)

    one = visits.find { |v| v[:ien] == "1" }
    two = visits.find { |v| v[:ien] == "2" }
    assert_equal "ASSESSMENT/EVALUATION-PATIENT PRESENT", one[:activity]
    refute one[:signed]
    assert two[:signed]
    refute_includes visits.map { |v| v[:ien] }, "T00010BMXIEN"
    assert_sent("visit_list")
  end

  def test_the_all_patient_lists_split_the_patient_pair
    replay("visits_all_patients")
    assert_equal({ ien: "990017", name: "QUEBEC,SAGE" }, E.visits_all_patients(**RANGE).find { |v| v[:ien] == "2" }[:patient])
    assert_sent("visits_all_patients")

    replay("suicide_forms_all_patients")
    forms = E.suicide_forms_all_patients(**RANGE).to_h { |f| [ f[:ien], f ] }
    assert forms["1"][:complete]
    refute forms["2"][:complete]
    assert_equal "DEMO-SF-2", forms["2"][:local_case_number]
    assert_sent("suicide_forms_all_patients")
  end

  def test_pcc_visit_choices_and_the_displays
    replay("pcc_visit_choices")
    assert_equal "F32.9-MAJOR DEPRESSIVE DISORDER SINGLE EPISODE", E.pcc_visit_choices("1").first[:pov]
    assert_sent("pcc_visit_choices")

    replay("record_display")
    assert_includes E.mhss_record_display("1"), "Patient Name:          QUEBEC,SAGE"
    assert_sent("record_display")

    replay("pcc_visit_display")
    assert_includes E.pcc_visit_display("120"), "Visit IEN:             120"

    replay("record_summary")
    summary = E.mhss_record_summary("1")
    assert_equal "Patient Name:          QUEBEC,SAGE", summary.first, "the count node is dropped"
    assert_sent("record_summary")
  end

  def test_screening_and_wellness
    replay("screening_history")
    assert_equal [ { ien: "2", date: "10/28/2026", type: "Depression", result: "POSITIVE", provider: "PROFILE,BH",
                     comment: "PHQ-9 score 21" } ], E.screening_history("990017", **RANGE)
    replay("wellness_activities")
    assert_equal "POSITIVE", E.wellness_activities("990017", **RANGE).first[:depression_screening]
  end

  def test_signature_status_reads_the_three_pieces
    replay("signature_signed")
    assert_equal({ can_sign: false, satisfied: true, message: "Note already signed, no E Sig necessary." }, E.signature_status("2"))
    replay("signature_unsigned")
    status = E.signature_status("1")
    refute status[:satisfied]
    assert_match(/A note must be entered/, status[:message])
  end

  def test_the_single_value_reads
    { "pcc_visit" => [ -> { E.pcc_visit?("1") }, true ],
      "suicide_form_other_information" => [ -> { E.suicide_form_other_information("1") },
                                            "Seen after the overdose; safety plan made with the client." ],
      "next_pcc_problem_number" => [ -> { E.next_pcc_problem_number("990017", facility: "7819") }, 3 ],
      "tiu_field" => [ -> { E.tiu_field(3101) }, 1108 ],
      "tiu_document" => [ -> { E.tiu_document("2", tiu_field: 1108) }, nil ],
      "activity_code" => [ -> { R.activity_code("12") }, { ien: "2", name: "ASSESSMENT/EVALUATION-PATIENT PRESENT", code: "12" } ],
      "activity_code_none" => [ -> { R.activity_code("ZZ9") }, nil ],
      "activity_passes_to_pcc" => [ -> { R.activity_passes_to_pcc?("2") }, true ],
      "version_current" => [ -> { R.version_current?("0.0") }, true ],
      "keys" => [ -> { R.keys }, [ "AMHZMENU", "AMHZ DATA ENTRY" ] ],
      "timeout" => [ -> { R.timeout("211") }, 600 ],
      "measurement_valid" => [ -> { R.measurement_validation("PHQ9", "12") }, { valid: true } ],
      "pov_passes_to_pcc" => [ -> { R.pov_passes_to_pcc?("1") }, true ],
      "locked" => [ -> { R.locked?(9_002_011, 1) }, false ] }.each do |flow, (call, expected)|
      replay(flow)
      expected.nil? ? assert_nil(call.call, flow) : assert_equal(expected, call.call, flow)
      assert_sent(flow)
    end
  end

  def test_the_patient_reads
    replay("pcc_problems")
    problems = E.pcc_problems("990017")
    assert_equal %w[F11.20 F32.9 Z59.0], problems.map { |p| p[:dx] }.sort
    assert_equal "DIC1", problems.find { |p| p[:dx] == "F32.9" }[:id], "the id's leading space is stripped"

    replay("demographics")
    banner = E.demographics("990017", facility: "7819")
    assert_equal "QUEBEC,SAGE", banner[:name]
    assert_equal "990017", banner[:chart]
    refute banner[:prf]
  end

  def test_the_list_reference_reads
    replay("health_summary_types")
    assert_includes R.health_summary_types, "BEHAVIORAL HEALTH"
    assert_equal [ [ "AMHG GET HEALTH SUMMARY TYPES", [] ] ], CapturedReplies.flow_calls(SLUG, "health_summary_types"),
                 "HS^AMHGT takes no actual"

    replay("field_codes")
    assert_equal [ "INTAKE", "REGULAR VISIT", "INFO/CONTACT", "SAN - NEW", "A/SA ENCOUNTER", "NO SHOW", "SAN - F/U", "BRIEF" ],
                 R.field_codes(9_002_011, ".33")

    replay("measurement_help")
    help = R.measurement_help("PHQ9")
    assert_equal "Enter a total PHQ9 score. Range: 0 - 27", help.first
    replay("measurement_invalid")
    assert_equal({ valid: false, help: help }, R.measurement_validation("PHQ9", "30"))
  end
end
