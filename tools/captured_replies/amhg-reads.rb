# frozen_string_literal: true

require "rpms_rpc/api/behavioral_health"
%w[case_management groups intake reference].each { |m| require "rpms_rpc/api/behavioral_health/#{m}" }

# Every Behavioral Health read, on the build as PROVIDER,TEST (rpms-rpc#619),
# one flow per public read method. The build ships no BH record, so before the
# run the throwaway container was given the BH visits the save captures file
# (amhg-save-visit.rb, amhg-save-pov.rb, amhg-save-progress-notes.rb,
# amhg-save-health-factors.rb, run against it first): DFN 990034's visit with a
# progress note, DFN 990035's with POVs and Axis III-V, DFN 990036's two, one
# in a group. No RPC files a treatment plan, a suicide form, an intake, a
# case or a community activity, so those reads answer what the build has:
# nothing. Reads only; the record IENs are the ones that container assigned.
BH = RpmsRpc::BehavioralHealth
RANGE = { from: "3200101", to: "3261231" }.freeze
$bh = {} # rubocop:disable Style/GlobalVars

def bh(key) = $bh.fetch(key) # rubocop:disable Style/GlobalVars

# A read the build answers with an M error is kept as the error it raises.
def kept_error
  yield
rescue RpmsRpc::Client::RpcError => e
  e.class
end

reads = {
  "visits" => [ "visits(990034): its BH visit, with a progress note", lambda {
    $bh[:note] = BH.visits(990_034, **RANGE).first.fetch(:ien) # rubocop:disable Style/GlobalVars
  } ],
  "visits_pov" => [ "visits(990035): its BH visit, with POVs", lambda {
    $bh[:pov] = BH.visits(990_035, **RANGE).first.fetch(:ien) # rubocop:disable Style/GlobalVars
  } ],
  "visits_group" => [ "visits(990036): two visits, one in a group", -> { BH.visits(990_036, **RANGE) } ],
  "visits_none" => [ "visits(990033): none", -> { BH.visits(990_033, **RANGE) } ],
  "visit_information" => [ "visit_information of DFN 990035's visit", -> { BH.visit_information(bh(:pov)) } ],
  "visit_information_none" => [ "visit_information of a record no visit has", -> { BH.visit_information(999_999) } ],
  "visit_activity" => [ "visit_activity of DFN 990035's visit", -> { BH.visit_activity(bh(:pov)) } ],
  "visit_axis_ii" => [ "visit_axis_ii of DFN 990035's visit", -> { BH.visit_axis_ii(bh(:pov)) } ],
  "visit_axis_iii" => [ "visit_axis_iii of DFN 990035's visit", -> { BH.visit_axis_iii(bh(:pov)) } ],
  "visit_axis_iv" => [ "visit_axis_iv of DFN 990035's visit", -> { BH.visit_axis_iv(bh(:pov)) } ],
  "visit_axis_v" => [ "visit_axis_v of DFN 990035's visit", -> { BH.visit_axis_v(bh(:pov)) } ],
  "visit_chief_complaint" => [ "visit_chief_complaint of DFN 990034's visit", -> { BH.visit_chief_complaint(bh(:note)) } ],
  "visit_chief_complaint_none" => [ "visit_chief_complaint of DFN 990035's visit, which has none",
                                    -> { BH.visit_chief_complaint(bh(:pov)) } ],
  "visit_soap" => [ "visit_soap of DFN 990034's visit", -> { BH.visit_soap(bh(:note)) } ],
  "visit_comment_appointment" => [ "visit_comment_appointment of DFN 990034's visit",
                                   -> { BH.visit_comment_appointment(bh(:note)) } ],
  "visit_assessment" => [ "visit_assessment of intake 1, which no intake has", -> { BH.visit_assessment(intake_ien: 1) } ],
  "visit_screenings" => [ "visit_screenings of DFN 990035's visit", -> { BH.visit_screenings(bh(:pov)) } ],
  "treatment_plans" => [ "treatment_plans(990035)", -> { BH.treatment_plans(990_035, **RANGE) } ],
  "treatment_plan" => [ "treatment_plan(1)", -> { BH.treatment_plan(1) } ],
  "treatment_plan_reviews" => [ "treatment_plan_reviews(1)", -> { BH.treatment_plan_reviews(1) } ],
  "treatment_plan_participants" => [ "treatment_plan_participants(1)", -> { BH.treatment_plan_participants(1) } ],
  "treatment_plan_narrative" => [ "treatment_plan_narrative(1)", -> { BH.treatment_plan_narrative(1) } ],
  "suicide_forms" => [ "suicide_forms(990035)", -> { BH.suicide_forms(990_035, **RANGE) } ],
  "suicide_form" => [ "suicide_form(1)", -> { BH.suicide_form(1) } ],
  "suicide_form_methods" => [ "suicide_form_methods(1)", -> { BH.suicide_form_methods(1) } ],
  "suicide_form_substances" => [ "suicide_form_substances(1)", -> { BH.suicide_form_substances(1) } ],
  "suicide_form_contributing_factors" => [ "suicide_form_contributing_factors(1)",
                                           -> { BH.suicide_form_contributing_factors(1) } ],
  "case_dates" => [ "CaseManagement.case_dates(990035)", -> { BH::CaseManagement.case_dates(990_035, **RANGE) } ],
  "case_management" => [ "CaseManagement.case_management(1)", -> { BH::CaseManagement.case_management(1) } ],
  "community_activities" => [ "CaseManagement.community_activities(200)",
                              -> { BH::CaseManagement.community_activities(200, **RANGE) } ],
  "community_activity" => [ "CaseManagement.community_activity(1)", -> { BH::CaseManagement.community_activity(1) } ],
  "groups" => [ "Groups.groups(200)", -> { BH::Groups.groups(200, **RANGE) } ],
  "group_information" => [ "Groups.group_information(1)", -> { BH::Groups.group_information(1) } ],
  "group_patients" => [ "Groups.group_patients(1)", -> { BH::Groups.group_patients(1) } ],
  "group_cpt" => [ "Groups.group_cpt(1)", -> { BH::Groups.group_cpt(1) } ],
  "group_edu" => [ "Groups.group_edu(1)", -> { BH::Groups.group_edu(1) } ],
  "group_pov" => [ "Groups.group_pov(1)", -> { BH::Groups.group_pov(1) } ],
  "group_soap" => [ "Groups.group_soap(1)", -> { BH::Groups.group_soap(1) } ],
  "group_secondary_providers" => [ "Groups.group_secondary_providers(1)", -> { BH::Groups.group_secondary_providers(1) } ],
  "intakes" => [ "Intake.intakes(990035)", -> { BH::Intake.intakes(990_035, **RANGE) } ],
  "intake_documents" => [ "Intake.intake_documents(990035)",
                          -> { BH::Intake.intake_documents(990_035, program: "MENTAL HEALTH", **RANGE) } ],
  "clinics" => [ "Reference.clinics", -> { BH::Reference.clinics } ],
  "patients" => [ "Reference.patients(\"IVORY\")", -> { BH::Reference.patients("IVORY") } ],
  "site_parameters" => [ "Reference.site_parameters(1)", -> { BH::Reference.site_parameters(1) } ],
  "admin_records" => [ "Reference.admin_records(200): the build answers an M error",
                       -> { kept_error { BH::Reference.admin_records(200, **RANGE) } } ]
}

CAPTURE = {
  rpc: "AMHG GET VISITS", entry_point: "VISITL^AMHGD",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair), the clinician that holds AMHGRPC",
  access: "PROV123", verify: "PROV123!!",
  note: "Reads only, on a throwaway container given BH visits by the amhg-save-* captures first.",
  calls: [],
  flows: reads.transform_values { |(about, run)| { about: about, run: run } }
}.freeze
