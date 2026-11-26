# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/behavioral_health/encounters"
require "rpms_rpc/api/behavioral_health/reference"
require "rpms_rpc/api/ddr_fileman"

# The Behavioral Health GUI's reads around one encounter, as the BH provider
# (PROFILE,BH), on the records the demo image seeds for the bh-cohort patient
# QUEBEC,SAGE (openrpms SEEDBH): two PCC-linked BH visits, the first at
# 10/14/2026 (activity 12, unsigned), the second at 10/28/2026 (a positive
# depression screening, "PHQ-9 score 21", signed); two suicide forms
# (DEMO-SF-1 complete, DEMO-SF-2 incomplete); and her PCC problems F32.9,
# F11.20 and Z59.0. Other live specs file further BH visits for her, so the
# lists are asserted to hold the seeded rows, never to be only them.
# Reads only; the refusal is BehavioralHealthEncountersRefusedLiveTest below.
class BehavioralHealthEncountersLiveTest < LiveSpec::Test
  runs_as :bh_provider
  needs "AMHGRPC", tracked: "openrpms#1299"

  E = RpmsRpc::BehavioralHealth::Encounters
  R = RpmsRpc::BehavioralHealth::Reference
  DFN = "990017" # QUEBEC,SAGE
  FIRST_VISIT = "1"
  SIGNED_VISIT = "2"
  COMPLETE_FORM = "1"
  FROM = "3000101"
  TO = "3271231"
  INSTITUTION = "7819" # DEMO IHS CLINIC (#4)

  def seeded(rows, ien) = rows.find { |row| row[:ien] == ien } || flunk("no row #{ien} in #{rows.inspect[0, 300]}")

  def test_the_record_selector_lists_the_seeded_visits_newest_first_with_their_signature_state
    visits = E.visit_list(DFN, from: FROM, to: TO)
    first = seeded(visits, FIRST_VISIT)
    signed = seeded(visits, SIGNED_VISIT)

    assert_equal "10/14/2026", first[:date]
    assert_equal "3261014", first[:sort_date]
    assert_equal "MAJOR DEPRESSIVE DISORDER SINGLE EPISODE", first[:pov]
    assert_equal "ASSESSMENT/EVALUATION-PATIENT PRESENT", first[:activity]
    assert_equal "PROFILE,BH", first[:provider]
    assert_equal "DEMO IHS CLINIC", first[:location]
    assert_equal "MENTAL HEALTH", first[:program]
    refute first[:signed], "visit 1 carries no signature"
    assert signed[:signed], "visit 2 was signed by PROFILE,BH"
    assert_equal "10/28/2026", signed[:date]
    assert_operator visits.index(signed), :<, visits.index(first), "newest first"
  end

  def test_the_all_patients_lists_carry_her_visits_and_suicide_forms
    visit = seeded(E.visits_all_patients(from: FROM, to: TO), SIGNED_VISIT)
    assert_equal({ ien: DFN, name: "QUEBEC,SAGE" }, visit[:patient])
    assert_equal "06/09/2001", visit[:dob]
    assert_equal "F", visit[:sex]

    forms = E.suicide_forms_all_patients(from: FROM, to: TO)
    one = seeded(forms, COMPLETE_FORM)
    two = seeded(forms, "2")
    assert_equal "DEMO-SF-1", one[:local_case_number]
    assert_equal "ATTEMPT", one[:suicidal_behavior]
    assert one[:complete]
    assert_equal "DEMO-SF-2", two[:local_case_number]
    refute two[:complete], "DEMO-SF-2 is filed incomplete"
    assert_equal({ ien: DFN, name: "QUEBEC,SAGE" }, two[:patient])
  end

  def test_a_record_offers_the_pcc_visit_it_links_to_and_says_it_has_one
    choices = E.pcc_visit_choices(FIRST_VISIT)

    refute_empty choices
    choice = choices.first
    assert_match(/\A\d+\z/, choice[:ien])
    assert_equal "10/14/2026", choice[:date]
    assert_equal "PROFILE,BH", choice[:provider]
    assert_equal "MENTAL HEALTH (PSYCHIATRY)", choice[:clinic]
    assert_equal "F32.9-MAJOR DEPRESSIVE DISORDER SINGLE EPISODE", choice[:pov]
    assert E.pcc_visit?(FIRST_VISIT), "SEEDBH links each BH visit to PCC"

    display = E.pcc_visit_display(choice[:ien])
    assert_includes display, "Visit IEN:             #{choice[:ien]}"
    assert(display.any? { |line| line.start_with?("PATIENT NAME:") && line.include?("QUEBEC,SAGE") }, display.first(12).inspect)
  end

  def test_both_record_displays_show_the_visit_and_its_patient
    gui = E.mhss_record_display(FIRST_VISIT)
    vuecentric = E.mhss_record_summary(FIRST_VISIT)

    [ gui, vuecentric ].each do |lines|
      assert_includes lines, "Patient Name:          QUEBEC,SAGE"
      assert_includes lines, "Chart #:               990017"
      assert_includes lines, "ACTIVITY TYPE NAME:    ASSESSMENT/EVALUATION-PATIENT PRESENT"
      assert(lines.any? { |line| line.start_with?("DATE OF SERVICE:") && line.include?("OCT 14, 2026@10:00") }, lines.first(10).inspect)
    end
    assert(vuecentric.any? { |line| line.include?("PROFILE,BH") }, "the VueCentric display lists the record's provider")
  end

  def test_the_screening_and_wellness_rows_carry_the_positive_depression_screening
    screening = seeded(E.screening_history(DFN, from: FROM, to: TO), SIGNED_VISIT)
    assert_equal({ ien: SIGNED_VISIT, date: "10/28/2026", type: "Depression", result: "POSITIVE",
                   provider: "PROFILE,BH", comment: "PHQ-9 score 21" }, screening)

    wellness = seeded(E.wellness_activities(DFN, from: FROM, to: TO), SIGNED_VISIT)
    assert_equal "POSITIVE", wellness[:depression_screening]
    assert_equal "10/28/2026", wellness[:date]
  end

  def test_the_signature_check_tells_a_signed_note_from_one_still_to_write
    assert_equal({ can_sign: false, satisfied: true, message: "Note already signed, no E Sig necessary." },
                 E.signature_status(SIGNED_VISIT))
    unsigned = E.signature_status(FIRST_VISIT)
    refute unsigned[:can_sign]
    refute unsigned[:satisfied]
    assert_match(/A note must be entered/, unsigned[:message])
  end

  def test_a_suicide_form_reads_its_other_relevant_information
    assert_equal "Seen after the overdose; safety plan made with the client.",
                 E.suicide_form_other_information(COMPLETE_FORM)
  end

  def test_the_patient_banner_and_pcc_problems_are_hers
    banner = E.demographics(DFN, facility: INSTITUTION)
    assert_equal "QUEBEC,SAGE", banner[:name]
    assert_equal "06/09/2001", banner[:dob]
    assert_equal "F", banner[:sex]
    assert_equal DFN, banner[:chart], "HRN = DFN on the panel"
    refute banner[:prf]

    problems = E.pcc_problems(DFN)
    assert_equal %w[F11.20 F32.9 Z59.0], problems.map { |p| p[:dx] }.sort
    depression = problems.find { |p| p[:dx] == "F32.9" }
    assert_equal "CHRONIC", depression[:status]
    assert_equal "DEMO IHS CLINIC", depression[:facility]
    assert_equal "09/01/2021", depression[:date_of_onset]
    numbers = problems.map { |p| p[:number].to_i }
    assert_equal numbers.max + 1, E.next_pcc_problem_number(DFN, facility: INSTITUTION)
  end

  def test_the_note_field_goes_through_tiu_and_a_seeded_record_points_at_no_document
    assert_equal 1108, E.tiu_field(3101), "a new record's SOAP note is edited through TIU field 1108"
    assert_equal 1108, E.tiu_field(3101, record_ien: SIGNED_VISIT), "the seeded note is TIU-backed, not word processing"
    assert_nil E.tiu_document(SIGNED_VISIT, tiu_field: 1108), "SEEDBH files the note in the record, not as a TIU document"
  end

  def test_reference_reads_answer_the_package_values
    assert_equal({ ien: "2", name: "ASSESSMENT/EVALUATION-PATIENT PRESENT", code: "12" }, R.activity_code("12"))
    assert_nil R.activity_code("ZZ9")
    assert R.activity_passes_to_pcc?("2"), "activity 12 passes to PCC"
    assert_includes R.health_summary_types, "BEHAVIORAL HEALTH"
    assert_equal [ "AMHZ DATA ENTRY", "AMHZMENU" ], R.keys.sort, "PROFILE,BH's AMH keys (README, Test roles)"
    assert_kind_of Integer, R.timeout(client.duz)
    assert R.version_current?("0.0"), "stock VC^AMHGUA answers 1 for any version"
    assert_includes R.field_codes(9_002_011, ".33"), "REGULAR VISIT"
    assert R.pov_passes_to_pcc?("1")
  end

  def test_a_measurement_is_validated_against_its_range
    help = R.measurement_help("PHQ9")
    assert_equal "Enter a total PHQ9 score. Range: 0 - 27", help.first

    assert_equal({ valid: true }, R.measurement_validation("PHQ9", "12"))
    refused = R.measurement_validation("PHQ9", "30")
    refute refused[:valid]
    assert_equal help, refused[:help]
  end
end

# AMHG CHECK LOCK asks whether another session holds a record's lock. A
# second session as the same role takes ^AMHREC(1) through DDR LOCK/UNLOCK
# NODE and releases it, so the answer is seen both ways. The lock is the only
# change and it is released in ensure.
class BehavioralHealthRecordLockLiveTest < LiveSpec::Test
  runs_as :bh_provider
  needs "AMHGRPC", tracked: "openrpms#1299"
  writes!

  def test_a_record_another_session_holds_reads_locked_until_it_is_released
    reference = RpmsRpc::BehavioralHealth::Reference
    refute reference.locked?(9_002_011, 1), "no one holds ^AMHREC(1) before the spec"

    other = RpmsRpc::CiaClient.new(host: ENV.fetch("BROKER_HOST"), port: Integer(ENV.fetch("BROKER_PORT")), timeout: 30)
    other.connect
    other.authenticate(*sign_on_pair)
    begin
      held = RpmsRpc.with_client(other) { RpmsRpc::DdrFileman.lock(node: "^AMHREC(1)", timeout: 2) }
      assert held, "the second session could not lock ^AMHREC(1)"
      assert reference.locked?(9_002_011, 1), "a lock held by another session reads locked"
    ensure
      RpmsRpc.with_client(other) { RpmsRpc::DdrFileman.unlock(node: "^AMHREC(1)") }
      other.disconnect
    end
    refute reference.locked?(9_002_011, 1), "released, it reads unlocked"
  end
end

# The front desk clerk holds no AMHGRPC (README, Test roles), so every one of
# these reads is refused before its routine runs: no BH record reaches a
# role outside behavioral health.
class BehavioralHealthEncountersRefusedLiveTest < LiveSpec::Test
  runs_as :front_desk_clerk

  E = RpmsRpc::BehavioralHealth::Encounters
  R = RpmsRpc::BehavioralHealth::Reference
  DFN = "990017"
  CALLS = {
    visit_list: -> { E.visit_list(DFN, from: "3000101", to: "3271231") },
    visits_all_patients: -> { E.visits_all_patients(from: "3000101", to: "3271231") },
    suicide_forms_all_patients: -> { E.suicide_forms_all_patients(from: "3000101", to: "3271231") },
    pcc_visit_choices: -> { E.pcc_visit_choices("1") },
    mhss_record_display: -> { E.mhss_record_display("1") },
    mhss_record_summary: -> { E.mhss_record_summary("1") },
    pcc_visit_display: -> { E.pcc_visit_display("1") },
    screening_history: -> { E.screening_history(DFN, from: "3000101", to: "3271231") },
    wellness_activities: -> { E.wellness_activities(DFN, from: "3000101", to: "3271231") },
    signature_status: -> { E.signature_status("2") },
    pcc_visit?: -> { E.pcc_visit?("1") },
    suicide_form_other_information: -> { E.suicide_form_other_information("1") },
    pcc_problems: -> { E.pcc_problems(DFN) },
    demographics: -> { E.demographics(DFN, facility: "7819") },
    next_pcc_problem_number: -> { E.next_pcc_problem_number(DFN, facility: "7819") },
    tiu_field: -> { E.tiu_field(3101) },
    tiu_document: -> { E.tiu_document("2", tiu_field: 1108) },
    activity_code: -> { R.activity_code("12") },
    activity_passes_to_pcc?: -> { R.activity_passes_to_pcc?("2") },
    health_summary_types: -> { R.health_summary_types },
    keys: -> { R.keys },
    timeout: -> { R.timeout("1") },
    version_current?: -> { R.version_current?("4.0") },
    field_codes: -> { R.field_codes(9_002_011, ".33") },
    pov_passes_to_pcc?: -> { R.pov_passes_to_pcc?("1") },
    locked?: -> { R.locked?(9_002_011, 1) },
    measurement_help: -> { R.measurement_help("PHQ9") },
    measurement_validation: -> { R.measurement_validation("PHQ9", "12") }
  }.freeze

  def test_every_read_is_refused_without_amhgrpc
    answered = CALLS.filter_map do |name, call|
      call.call
      name
    rescue RpmsRpc::Client::RpcRefusedError, RpmsRpc::Client::ContextRefusedError
      nil
    end
    assert_empty answered, "#{role} holds no AMHGRPC and these answered: #{answered.join(', ')}"
  end
end
