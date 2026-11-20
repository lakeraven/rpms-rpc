# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/behavioral_health/reference"
require "rpms_rpc/api/behavioral_health/groups"
require "rpms_rpc/api/behavioral_health/case_management"

# The AMHG treatment-plan, suicide-form, visit-tab and group reads over the
# wire, under AMHGRPC. Each answers parsed rows, never the recordset's typed
# header read as a record: before these specs, eight of them handed the
# header back as a row whose IEN was "<seq>\x00T00010BMXIEN". Reads only.
# The visit tabs of a filed visit are read in behavioral_health_save_pov_live_test.rb.
class BehavioralHealthRecordsLiveTest < LiveSpec::Test
  # The clinician holds AMHGRPC from bcer-9.0-20261119-f67498c-ydb (openrpms#1192, #814).
  runs_as "PROV123"
  BH = RpmsRpc::BehavioralHealth
  DEMO_DFN = "4"
  FROM = "3000101"
  TO = "3271231"
  NOT_ON_FILE = "999999"
  HEADER = /T\d{5}|BMXIEN/

  def assert_no_header(name, rows)
    assert_kind_of Array, rows, name
    rows.each { |row| refute_match(HEADER, row.values.join("|"), "#{name}: the typed header read as a record: #{row.inspect}") }
  end

  def test_treatment_plans_and_suicide_forms_list_records_only
    plans = BH.treatment_plans(DEMO_DFN, from: FROM, to: TO)
    forms = BH.suicide_forms(DEMO_DFN, from: FROM, to: TO)
    assert_no_header(:treatment_plans, plans)
    assert_no_header(:suicide_forms, forms)
    (plans + forms).each { |row| assert_match(/\A\d+\z/, row[:ien].to_s, "a row whose IEN is not a record IEN: #{row.inspect}") }
  end

  # The build answers one row echoing the IEN asked for, with its fields
  # blank; the single-record reads answer nil for it (#882), never the header.
  def test_single_record_reads_of_a_record_not_on_file
    assert_nil BH.treatment_plan(NOT_ON_FILE)
    assert_nil BH.suicide_form(NOT_ON_FILE)
    assert_empty BH.suicide_form_substances(NOT_ON_FILE)
    assert_nil BH.visit_information(NOT_ON_FILE)
    assert_nil BH::CaseManagement.case_management(NOT_ON_FILE)
    assert_nil BH::Groups.group_information(NOT_ON_FILE)
    assert_equal NOT_ON_FILE, BH.visit_activity(NOT_ON_FILE)[:ien]
    assert_equal({ axis_v: nil, gaf: nil }, BH.visit_axis_v(NOT_ON_FILE))
    assert_nil BH.visit_chief_complaint(NOT_ON_FILE)
  end

  def test_child_lists_of_a_record_not_on_file_are_empty
    lists = {
      treatment_plan_reviews: BH.treatment_plan_reviews(NOT_ON_FILE),
      treatment_plan_participants: BH.treatment_plan_participants(NOT_ON_FILE),
      treatment_plan_narrative: BH.treatment_plan_narrative(NOT_ON_FILE),
      suicide_form_methods: BH.suicide_form_methods(NOT_ON_FILE),
      suicide_form_contributing_factors: BH.suicide_form_contributing_factors(NOT_ON_FILE),
      visit_axis_ii: BH.visit_axis_ii(NOT_ON_FILE),
      visit_axis_iii: BH.visit_axis_iii(NOT_ON_FILE),
      visit_axis_iv: BH.visit_axis_iv(NOT_ON_FILE),
      visit_screenings: BH.visit_screenings(NOT_ON_FILE),
      visit_assessment: BH.visit_assessment(intake_ien: NOT_ON_FILE),
      group_cpt: BH::Groups.group_cpt(NOT_ON_FILE, dupe: "", date: ""),
      group_edu: BH::Groups.group_edu(NOT_ON_FILE),
      group_pov: BH::Groups.group_pov(NOT_ON_FILE, dupe: "", date: ""),
      group_secondary_providers: BH::Groups.group_secondary_providers(NOT_ON_FILE)
    }
    lists.each { |name, rows| assert_empty rows, "#{name} of #{NOT_ON_FILE}: #{rows.inspect}" }
  end

  # SUB^AMHGDSF writes its one row whether or not the form is on file: the
  # form IEN with the substance columns blank.
  def test_suicide_form_substances_of_a_form_not_on_file_is_one_blank_row
    rows = BH.suicide_form_substances(NOT_ON_FILE)
    assert_no_header(:suicide_form_substances, rows)
    rows.each { |row| assert_equal NOT_ON_FILE, row[:form_ien] }
  end

  # CLN^AMHGTVF is a stub: RETVAL with no header, no rows and no $C(31).
  def test_clinics_is_empty_not_a_blank_record
    assert_equal [], BH::Reference.clinics
  end
end
