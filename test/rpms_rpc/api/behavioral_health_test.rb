# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/behavioral_health/case_management"
require "rpms_rpc/api/behavioral_health/groups"
require "rpms_rpc/api/behavioral_health/intake"
require "rpms_rpc/api/behavioral_health/reference"
require "rpms_rpc/api/behavioral_health/encounters"
require_relative "behavioral_health/amhg_replay"

# Tests for RpmsRpc::BehavioralHealth — the AMHG (IHS Behavioral Health) RPC
# surface (rpms-rpc#227) — on the build's replies. Every read was captured as
# PROVIDER,TEST on a throwaway container given BH visits by the stock save
# RPCs (test/fixtures/captured_replies/amhg-reads.yml, one flow per read):
# DFN 990034's visit 4 with a progress note, DFN 990035's visit 3 with POVs
# and Axis III-V, DFN 990036's visits 1 and 2. The build has no treatment
# plan, suicide form, intake or screening (openrpms#1272), so those reads
# answer what it has; the saves are tested in behavioral_health/save_*_test.rb.
class BehavioralHealthTest < Minitest::Test
  BH = RpmsRpc::BehavioralHealth
  SLUG = "amhg-reads"
  RANGE = { from: "3200101", to: "3261231" }.freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow) = @client = AmhgReplay.flow(SLUG, flow)
  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  # -- AMHG GET VISITS -------------------------------------------------------

  def test_visits_parses_the_seventeen_field_row_and_skips_the_header
    replay("visits_pov")

    visits = BH.visits(990_035, **RANGE)

    assert_equal 1, visits.length, "header and $C(31) terminator are not records"
    assert_equal({ ien: "3", visit_date: "3261120", display_date: "11/20/2026", pov: "SYNTH POV NARR C",
                   clinic: "ALCOHOL AND SUBSTANCE", provider: "PROVIDER,TEST", program: "MENTAL HEALTH" },
                 visits.first.slice(:ien, :visit_date, :display_date, :pov, :clinic, :provider, :program))
  end

  # AMHGD.m:47 — AMHESIG is "*" when field 1112 is FALSE, i.e. the star means
  # NOT signed. No visit the save RPCs file is signed (openrpms#1267), so the
  # build's rows all carry the star.
  def test_signed_is_inverted_on_the_wire
    replay("visits_group")
    raw = CapturedReplies.raw(SLUG, "visits_group/1")

    visits = BH.visits(990_036, **RANGE)

    assert_includes raw, "^PROVIDER,TEST^*^", 'the build marks each unsigned visit "*"'
    assert_equal [ false, false ], visits.map { _1[:signed] }, '"*" in the Signed column means NOT signed'
  end

  # AMHGD.m:53 computes AMHDOBI and AMHGD.m:55 never appends it.
  def test_dob_declared_in_the_header_is_never_emitted_so_is_not_invented
    replay("visits_pov")

    assert_includes CapturedReplies.raw(SLUG, "visits_pov/1"), "T00030DOBI"
    refute BH.visits(990_035, **RANGE).first.key?(:dob), "header declares T00030DOBI but AMHGD.m:55 emits 17 fields"
  end

  # AMHGD.m:23-26 walks ^AMHREC("AE") over INVERSE dates: newest first. DFN
  # 990036's visit 2 was filed after visit 1, its group visit.
  def test_rows_are_returned_in_wire_order_newest_first_with_the_group_flag
    replay("visits_group")

    visits = BH.visits(990_036, **RANGE)

    assert_equal [ [ "2", false ], [ "1", true ] ], visits.map { [ _1[:ien], _1[:group] ] }
  end

  def test_visits_sends_one_pipe_delimited_parameter
    replay("visits_pov")
    BH.visits(990_035, **RANGE)

    assert_equal [ [ "AMHG GET VISITS", [ "3200101|3261231|990035" ] ] ], sent,
                 "AMH rejects multi-actual calls with YDB-E-ACTLSTTOOLONG (#198)"
  end

  def test_visits_with_no_records_returns_empty
    replay("visits_none")

    assert_empty BH.visits(990_033, **RANGE)
  end

  # ADML^AMHGDA's MERR^AMHGU trap writes "M ERROR|<text>" over row 1
  # (openrpms#1119): the build's reply for AMHG GET ADMIN RECORDS. It raises;
  # it is never a record with an IEN of "M ERROR|...".
  def test_an_m_error_row_raises
    replay("admin_records")

    error = assert_raises(RpmsRpc::Client::RpcMError) { BH::Reference.admin_records(200, **RANGE) }
    assert_match(/\AM ERROR\|MUMPS error/, error.message)
  end

  # -- AMHG GET VISIT INFORMATION -------------------------------------------

  # Five columns carry an IEN~external pair (R="~" at AMHGDVF.m:12); Program
  # and ApptWi are external-only (AMHGDVF.m:27, :45); AMHGDVF.m:40 blanks the
  # arrival time unconditionally.
  def test_visit_information_splits_ien_name_pairs_and_keeps_external_only_columns
    replay("visit_information")

    info = BH.visit_information(3)

    assert_equal({ ien: "200", name: "PROVIDER,TEST" }, info[:primary_provider])
    assert_equal({ ien: "63", name: "ALCOHOL AND SUBSTANCE" }, info[:clinic])
    assert_equal({ ien: "1", name: "ADMINISTRATIVE" }, info[:type_of_contact])
    assert_equal({ ien: "7819", name: "DEMO IHS CLINIC" }, info[:encounter_location])
    assert_equal({ ien: "7421", name: "11-MILE CORN" }, info[:community_of_service])
    assert_equal [ "MENTAL HEALTH", "WALK-IN" ], info.values_at(:program, :appointment_with)
    assert_nil info[:arrival_time]
    assert_equal [ [ "AMHG GET VISIT INFORMATION", [ "3" ] ] ], sent
  end

  # The build's row for a visit not on file: the IEN, the signed-on user as
  # provider and the empty date "1700,,,12,0" (#882).
  def test_visit_information_is_nil_for_a_visit_not_on_file
    replay("visit_information_none")

    assert_nil BH.visit_information(999_999)
    assert_equal [ [ "AMHG GET VISIT INFORMATION", [ "999999" ] ] ], sent
  end

  # For an IEN not on file the detail reads echo it in a row of blanks (#882).
  def test_treatment_plan_is_nil_when_the_row_echoes_only_the_ien
    replay("treatment_plan")

    assert_nil BH.treatment_plan(1)
  end

  def test_substances_for_a_form_not_on_file_are_empty
    replay("suicide_form_substances")

    assert_empty BH.suicide_form_substances(1)
  end

  # -- visit detail tabs -----------------------------------------------------

  # ACT^AMHGDVF (AMHGDVF.m:291): the build's visits carry no activity type or
  # site (openrpms#1272); a blank interpreter flag reads false.
  def test_visit_activity_reports_a_blank_interpreter_flag_as_false
    replay("visit_activity")

    act = BH.visit_activity(3)

    assert_equal "3", act[:ien]
    assert_nil act[:activity_type]
    refute act[:interpreter_utilized], "AMHGDVF.m:311 blanks the flag when falsy"
  end

  # AMHGDVF.m:67 — the column called BMXIEN is field .01's INTERNAL value, a
  # pointer to the code file, not the subfile IEN.
  def test_axis_ii_and_iv_first_column_is_a_code_pointer_not_a_record_ien
    replay("visit_axis_ii")
    povs = BH.visit_axis_ii(3)
    assert_equal 1, povs.length
    pov = povs.first
    assert_equal({ code_pointer: "2", code: "2", narrative: "SYNTH POV NARR C" }, pov)
    refute pov.key?(:ien), "the subfile IEN is never emitted (AMHGDVF.m:64)"

    replay("visit_axis_iv")
    assert_equal({ code_pointer: "3", code: "3", narrative: "EDUCATIONAL PROBLEMS" }, BH.visit_axis_iv(3).first)
  end

  def test_axis_iii_returns_raw_lines
    replay("visit_axis_iii")

    assert_equal [ "SYNTH AXIS III LINE" ], BH.visit_axis_iii(3)
  end

  # AXIS5 always emits exactly one row — there is no loop (AMHGDVF.m:123).
  def test_axis_v_returns_one_row_with_its_gaf_column
    replay("visit_axis_v")

    assert_equal({ axis_v: "70", gaf: nil }, BH.visit_axis_v(3))
  end

  def test_chief_complaint_is_the_text_and_nil_when_the_single_row_is_blank
    replay("visit_chief_complaint")
    assert_equal "SYNTH CC", BH.visit_chief_complaint(4)

    replay("visit_chief_complaint_none")
    assert_nil BH.visit_chief_complaint(3)
  end

  def test_soap_and_comment_return_raw_lines
    replay("visit_soap")
    assert_equal [ "SYNTH note after blank comment." ], BH.visit_soap(4)

    replay("visit_comment_appointment")
    assert_equal [ "SYNTH comment line A\n", "SYNTH comment line B" ], BH.visit_comment_appointment(4)
  end

  # AMHGDINT.m:114 walks ^AMHRINTK(ien,41) — the parameter is an INTAKE IEN
  # despite the RPC being named GET VISIT ASSESSMENT.
  def test_assessment_is_keyed_by_intake_ien
    replay("visit_assessment")

    assert_equal [], BH.visit_assessment(intake_ien: 1)
    assert_equal [ [ "AMHG GET VISIT ASSESSMENT", [ "1" ] ] ], sent
  end

  def test_screening_is_empty_when_no_screening_has_a_result
    replay("visit_screenings")

    assert_empty BH.visit_screenings(3)
  end

  # -- lists the build has no rows for (openrpms#1272) -----------------------

  { treatment_plans: [ :treatment_plans, [ 990_035 ] ], suicide_forms: [ :suicide_forms, [ 990_035 ] ] }
    .each do |flow, (method, args)|
    define_method("test_#{flow}_header_only_is_empty") do
      replay(flow.to_s)
      assert_empty BH.public_send(method, *args, **RANGE)
    end
  end

  { treatment_plan_reviews: 1, treatment_plan_participants: 1, treatment_plan_narrative: 1,
    suicide_form_methods: 1, suicide_form_contributing_factors: 1 }.each do |method, ien|
    define_method("test_#{method}_header_only_is_empty") do
      replay(method.to_s)
      assert_empty BH.public_send(method, ien)
      assert_equal [ [ ien.to_s ] ], sent.map(&:last)
    end
  end

  # -- AMHGRPC context binding (rpms-rpc#258) --------------------------------
  #
  # RPC registration is OPTION-scoped (RpmsRpc::ContextScope). On a built 9.0
  # image every AMHG RPC this module and its clusters call is in the RPC
  # multiple of ONE file-19 option, AMHGRPC, and in none of the options a
  # signed-on session is otherwise holding. Every AMHG call goes through
  # Wire#call_amhg, so that is where AMHGRPC is bound and the caller's option
  # restored, as RpmsRpc::Agg does for AGGRPC.

  # Arguments that let every public method reach the wire. The read rows are
  # what the amhg-reads flows sent; the saves' rows are kept for the table
  # test, and their binds are proven on the build's replies in
  # behavioral_health/save_*_test.rb.
  AMHG_CALLS = {
    BH => {
      visits: [ 100, { from: "3250101", to: "3251231" } ],
      visit_information: [ 8801 ],
      save_visit: [ {
        provider: "412", encounter_date: "3251031", patient: "100",
        program: "MENTAL HEALTH", clinic: "17", type_of_contact: "3",
        encounter_location: "55", community_of_service: "42"
      } ],
      save_pcc_visit: [ { record_ien: "8801" } ],
      save_pov: [ {
        record_ien: "8801", patient: "100",
        diagnoses: [ { problem: "501", narrative: "SYNTH POV NARR A" } ],
        axis_iv: [], axis_v: "55", gaf: "12"
      } ],
      save_progress_note: [ {
        record_ien: "8801", patient: "100", chief_complaint: "SYN CC",
        note: "SYNTH progress note.", comment: "SYNTH comment.",
        placement_disposition: "12", referred_to: "SYN REF"
      } ],
      save_health_factors: [ {
        record_ien: "8801", patient: "100", mode: :edit,
        health_factors: [ { name: "SYN FACTOR A", level: "MINIMAL", quantity: "1", comment: "SYN CTX" } ]
      } ],
      visit_activity: [ 8801 ],
      visit_axis_ii: [ 8801 ],
      visit_axis_iv: [ 8801 ],
      visit_axis_iii: [ 8801 ],
      visit_axis_v: [ 8801 ],
      visit_chief_complaint: [ 8801 ],
      visit_soap: [ 8801 ],
      visit_comment_appointment: [ 8801 ],
      visit_assessment: [ { intake_ien: 12 } ],
      visit_screenings: [ 8801 ],
      treatment_plans: [ 100, { from: "3250101", to: "3251231" } ],
      treatment_plan: [ 55 ],
      treatment_plan_reviews: [ 55 ],
      treatment_plan_participants: [ 55 ],
      treatment_plan_narrative: [ 55 ],
      suicide_forms: [ 100, { from: "3250101", to: "3251231" } ],
      suicide_form: [ 31 ],
      suicide_form_methods: [ 31 ],
      suicide_form_substances: [ 31 ],
      suicide_form_contributing_factors: [ 31 ]
    },
    BH::CaseManagement => {
      case_dates: [ 100, { from: "3250101", to: "3251231" } ],
      case_management: [ 9 ],
      community_activities: [ 412, { from: "3250101", to: "3251231" } ],
      community_activity: [ 9 ]
    },
    BH::Groups => {
      groups: [ 412, { from: "3250101", to: "3251231" } ],
      group_information: [ 5 ],
      group_patients: [ 5 ],
      group_cpt: [ 5 ],
      group_edu: [ 5 ],
      group_pov: [ 5 ],
      group_soap: [ 5 ],
      group_secondary_providers: [ 5 ]
    },
    BH::Intake => {
      intakes: [ 100, { from: "3250101", to: "3251231" } ],
      intake_documents: [ 100, { program: "ADULT OUTPATIENT", from: "3250101", to: "3251231" } ]
    },
    BH::Reference => {
      clinics: [],
      patients: [ "PATIENT,EXAMPLE" ],
      site_parameters: [ 1 ],
      admin_records: [ 412, { from: "3250101", to: "3251231" } ],
      health_summary_types: [],
      activity_code: [ "12" ],
      activity_passes_to_pcc?: [ "2" ],
      version_current?: [ "0.0" ],
      keys: [],
      timeout: [ "211" ],
      measurement_help: [ "PHQ9" ],
      measurement_validation: [ "PHQ9", "12" ],
      pov_passes_to_pcc?: [ "1" ],
      locked?: [ 9_002_011, 1 ],
      field_codes: [ 9_002_011, ".33" ]
    },
    BH::Encounters => {
      visit_list: [ "990017", { from: "3000101", to: "3271231" } ],
      visits_all_patients: [ { from: "3000101", to: "3271231" } ],
      suicide_forms_all_patients: [ { from: "3000101", to: "3271231" } ],
      pcc_visit_choices: [ "1" ],
      mhss_record_display: [ "1" ],
      pcc_visit_display: [ "120" ],
      mhss_record_summary: [ "1" ],
      screening_history: [ "990017", { from: "3000101", to: "3271231" } ],
      wellness_activities: [ "990017", { from: "3000101", to: "3271231" } ],
      signature_status: [ "2" ],
      pcc_visit?: [ "1" ],
      suicide_form_other_information: [ "1" ],
      pcc_problems: [ "990017" ],
      demographics: [ "990017", { facility: "7819" } ],
      next_pcc_problem_number: [ "990017", { facility: "7819" } ],
      tiu_field: [ 3101 ],
      tiu_document: [ "2", { tiu_field: 1108 } ]
    }
  }.freeze

  # The reads added with BehavioralHealth::Encounters replay the demo image's
  # replies in amhg-encounters.yml, each from the flow named here (the method's
  # name unless listed), with exactly the arguments AMHG_CALLS gives it.
  ENCOUNTERS_SLUG = "amhg-encounters"
  ENCOUNTERS_FLOWS = Hash.new { |_, method| method.to_s.delete_suffix("?").delete_prefix("mhss_") }
                         .merge(signature_status: "signature_signed", measurement_validation: "measurement_valid").freeze
  def encounters_call?(mod, method)
    mod == BH::Encounters || (mod == BH::Reference && !%i[clinics patients site_parameters admin_records].include?(method))
  end

  def test_the_bind_table_names_every_public_method_of_every_cluster
    AMHG_CALLS.each do |mod, table|
      expected = mod.public_instance_methods(false).sort - RpmsRpc::BehavioralHealth::Wire.instance_methods

      assert_equal expected, table.keys.sort,
        "a new #{mod} method must be added to AMHG_CALLS so its context bind is proven"
    end
  end

  SAVES = %i[save_visit save_pcc_visit save_pov save_progress_note save_health_factors].freeze
  # The flow of amhg-reads.yml each read replays, and the arguments that flow used.
  READ_FLOWS = Hash.new { |_, method| method.to_s }.merge(visits: "visits_pov").freeze
  READ_ARGS = {
    visits: [ 990_035, RANGE ], visit_information: [ 3 ], visit_assessment: [ { intake_ien: 1 } ], visit_activity: [ 3 ], visit_axis_ii: [ 3 ],
    visit_axis_iv: [ 3 ], visit_axis_iii: [ 3 ], visit_axis_v: [ 3 ], visit_chief_complaint: [ 4 ],
    visit_soap: [ 4 ], visit_comment_appointment: [ 4 ], visit_screenings: [ 3 ],
    treatment_plans: [ 990_035, RANGE ], suicide_forms: [ 990_035, RANGE ], case_dates: [ 990_035, RANGE ],
    community_activities: [ 200, RANGE ], groups: [ 200, RANGE ], intakes: [ 990_035, RANGE ],
    intake_documents: [ 990_035, { program: "MENTAL HEALTH", **RANGE } ], patients: [ "IVORY" ],
    admin_records: [ 200, RANGE ]
  }.freeze

  def test_every_amhg_read_runs_under_amhgrpc_and_restores_the_callers_context
    AMHG_CALLS.each do |mod, table|
      table.each_key do |method|
        next if mod == BH && SAVES.include?(method)

        slug, flow = encounters_call?(mod, method) ? [ ENCOUNTERS_SLUG, ENCOUNTERS_FLOWS[method] ] : [ SLUG, READ_FLOWS[method] ]
        client = AmhgReplay.flow(slug, flow)
        args = if encounters_call?(mod, method)
          table.fetch(method)
        else
          READ_ARGS.fetch(method) { table.fetch(method).map { |a| a.is_a?(Integer) ? 1 : a } }
        end
        positional = args.reject { |a| a.is_a?(Hash) }
        keywords = args.find { |a| a.is_a?(Hash) } || {}
        begin
          mod.public_send(method, *positional, **keywords)
        rescue RpmsRpc::Client::RpcMError
          nil # admin_records: the build's M error row, after the call
        end

        calls = client.calls.reject { |c| c[:rpc] == :create_context }
        refute_empty calls, "#{mod}.#{method} made no RPC call"
        calls.each do |call|
          assert_equal "AMHGRPC", call[:context],
            "#{mod}.#{method} sent #{call[:rpc]} under #{call[:context].inspect}; the AMHG RPCs are registered under AMHGRPC only"
        end
        assert_equal CapturedReplies.flow_calls(slug, flow), calls.map { |c| [ c[:rpc], c[:params] ] },
                     "#{mod}.#{method} sent what the build was sent"
        assert_equal AmhgReplay::Client::SIGNON_CONTEXT, client.current_context,
          "#{mod}.#{method} left the session on #{client.current_context.inspect}"
        assert_equal [ "AMHGRPC", AmhgReplay::Client::SIGNON_CONTEXT ], client.binds, "#{mod}.#{method} context binds"
      end
    end
  end

  def test_save_screening_and_save_measurements_are_owned_by_wellness_not_behavioral_health
    refute BH.respond_to?(:save_screening),
           "Wellness owns save_screening; remove duplicate from BehavioralHealth"
    refute BH.respond_to?(:save_measurements),
           "Wellness owns save_measurements; remove duplicate from BehavioralHealth"
  end

  def test_an_amhgrpc_that_will_not_bind_raises_before_any_rpc_is_sent
    client = AmhgReplay.flow(SLUG, "visit_soap").refuse_bind("AMHGRPC")

    assert_raises(RpmsRpc::Client::RpcError) { BH.visit_soap(4) }
    assert_empty client.calls.reject { |c| c[:rpc] == :create_context }
  end
end
