# frozen_string_literal: true

require "rpms_rpc/api/behavioral_health/encounters"
require "rpms_rpc/api/behavioral_health/reference"

# The Behavioral Health GUI's reads around one encounter, as
# BehavioralHealth::Encounters and the new BehavioralHealth::Reference reads
# send them under AMHGRPC, recorded as flows as the BH provider test role on
# the demo image's seeded records for QUEBEC,SAGE (DFN 990017, openrpms
# SEEDBH): BH visits 1 and 2, suicide form 1, her PCC problems. Reads only.
E = RpmsRpc::BehavioralHealth::Encounters
R = RpmsRpc::BehavioralHealth::Reference
RANGE = { from: "3000101", to: "3271231" }.freeze
CAPTURE = {
  rpc: "AMHG GET VISIT LIST", entry_point: "VISITL^AMHGD",
  signed_on_as: "PROFILE,BH (PBH123, the bh_provider test role's published demo pair)",
  access: "PBH123", verify: "PBH123!!",
  note: "Reads only, on the demo image's SEEDBH records. Pieces are begin|end|dfn for the lists, a record, " \
        "visit or form IEN for the single-record reads, dfn|A for the PCC problems and facility|dfn for the banner.",
  flows: {
    "visit_list" => { about: "Encounters.visit_list(990017) over 2000-2027", run: -> { E.visit_list("990017", **RANGE) } },
    "visits_all_patients" => { about: "Encounters.visits_all_patients over 2000-2027",
                               run: -> { E.visits_all_patients(**RANGE) } },
    "suicide_forms_all_patients" => { about: "Encounters.suicide_forms_all_patients over 2000-2027",
                                      run: -> { E.suicide_forms_all_patients(**RANGE) } },
    "pcc_visit_choices" => { about: "Encounters.pcc_visit_choices(1)", run: -> { E.pcc_visit_choices("1") } },
    "record_display" => { about: "Encounters.record_display(1)", run: -> { E.mhss_record_display("1") } },
    "pcc_visit_display" => { about: "Encounters.pcc_visit_display(120): visit 1's PCC visit on this image", run: -> { E.pcc_visit_display("120") } },
    "record_summary" => { about: "Encounters.record_summary(1): AMHBH RECORD DISPLAY", run: -> { E.mhss_record_summary("1") } },
    "screening_history" => { about: "Encounters.screening_history(990017)",
                             run: -> { E.screening_history("990017", **RANGE) } },
    "wellness_activities" => { about: "Encounters.wellness_activities(990017)",
                               run: -> { E.wellness_activities("990017", **RANGE) } },
    "signature_signed" => { about: "Encounters.signature_status(2): the signed visit", run: -> { E.signature_status("2") } },
    "signature_unsigned" => { about: "Encounters.signature_status(1): no note yet", run: -> { E.signature_status("1") } },
    "pcc_visit" => { about: "Encounters.pcc_visit?(1)", run: -> { E.pcc_visit?("1") } },
    "suicide_form_other_information" => { about: "Encounters.suicide_form_other_information(1)",
                                          run: -> { E.suicide_form_other_information("1") } },
    "pcc_problems" => { about: "Encounters.pcc_problems(990017)", run: -> { E.pcc_problems("990017") } },
    "demographics" => { about: "Encounters.demographics(990017, facility: 7819)",
                        run: -> { E.demographics("990017", facility: "7819") } },
    "next_pcc_problem_number" => { about: "Encounters.next_pcc_problem_number(990017, facility: 7819)",
                                   run: -> { E.next_pcc_problem_number("990017", facility: "7819") } },
    "tiu_field" => { about: "Encounters.tiu_field(3101): a new record", run: -> { E.tiu_field(3101) } },
    "tiu_document" => { about: "Encounters.tiu_document(2, tiu_field: 1108)", run: -> { E.tiu_document("2", tiu_field: 1108) } },
    "health_summary_types" => { about: "Reference.health_summary_types", run: -> { R.health_summary_types } },
    "activity_code" => { about: "Reference.activity_code(12)", run: -> { R.activity_code("12") } },
    "activity_code_none" => { about: "Reference.activity_code(ZZ9): no such code", run: -> { R.activity_code("ZZ9") } },
    "activity_passes_to_pcc" => { about: "Reference.activity_passes_to_pcc?(2)", run: -> { R.activity_passes_to_pcc?("2") } },
    "version_current" => { about: "Reference.version_current?(0.0)", run: -> { R.version_current?("0.0") } },
    "keys" => { about: "Reference.keys: PROFILE,BH's AMH keys", run: -> { R.keys } },
    "timeout" => { about: "Reference.timeout(211): PROFILE,BH", run: -> { R.timeout("211") } },
    "measurement_help" => { about: "Reference.measurement_help(PHQ9)", run: -> { R.measurement_help("PHQ9") } },
    "measurement_valid" => { about: "Reference.measurement_validation(PHQ9, 12)", run: -> { R.measurement_validation("PHQ9", "12") } },
    "measurement_invalid" => { about: "Reference.measurement_validation(PHQ9, 30)", run: -> { R.measurement_validation("PHQ9", "30") } },
    "pov_passes_to_pcc" => { about: "Reference.pov_passes_to_pcc?(1)", run: -> { R.pov_passes_to_pcc?("1") } },
    "locked" => { about: "Reference.locked?(9002011, 1): nobody holds it", run: -> { R.locked?(9_002_011, 1) } },
    "field_codes" => { about: "Reference.field_codes(9002011, .33): VISIT TYPE", run: -> { R.field_codes(9_002_011, ".33") } }
  }
}.freeze
