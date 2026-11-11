# frozen_string_literal: true

# One reply per read frame test/rpms_rpc/api/read_call_formals_test.rb pins,
# sent in exactly that frame for demo patient DFN 4, as PROFILE,MD under
# CIAV VUECENTRIC (#259: each read sends the formals its routine declares).
# rpms-rpc#621.
VSTR = "349;3260514.09;A;2090059"

CAPTURE = {
  rpc: "ORQQPS LIST", entry_point: "LIST^ORQQPS",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Seed patient DFN 4 (synthetic data); every call is a read.",
  calls: [
    { name: "orqqps_list", inputs: [ "4", "", "" ], about: "Medication.for_patient: DFN and both dates" },
    { name: "orwps_active", rpc: "ORWPS ACTIVE", inputs: [ "4" ], about: "Medication.active_for_patient: DFN only" },
    { name: "orqqpl_list", rpc: "ORQQPL LIST", inputs: [ "4", "" ], about: "Problem.for_patient: DFN and status (all)" },
    { name: "orqqpl_detail", rpc: "ORQQPL DETAIL", inputs: [ "4", "1" ], about: "Problem.details: DFN then problem 1" },
    { name: "orqqpl_edit_load", rpc: "ORQQPL EDIT LOAD", inputs: [ "1", "206", "7819" ],
      about: "Problem.edit_load: problem 1, provider PROFILE,MD (206), institution 7819" },
    { name: "tiu_template_gettext", rpc: "TIU TEMPLATE GETTEXT",
      inputs: [ "4", VSTR, { [ 1, 0 ] => "Patient |PATIENT NAME|", [ 2, 0 ] => "Age |PATIENT AGE|" } ],
      about: "NoteTemplate.text: DFN, visit string, the text as TIUX(n,0) nodes" },
    { name: "orwor_result", rpc: "ORWOR RESULT", inputs: [ "4", "1", "1" ], about: "Order.result: DFN then order 1 twice" },
    { name: "orwdal32_symptoms", rpc: "ORWDAL32 SYMPTOMS", inputs: [ "COUGH", "1" ], about: "Symptom.search: FROM and direction" },
    { name: "behovm_template", rpc: "BEHOVM TEMPLATE", inputs: [ "4", VSTR, "-1" ],
      about: "Vital.template: DFN, visit string, default units" },
    { name: "behovm_template_metric", rpc: "BEHOVM TEMPLATE", inputs: [ "4", VSTR, "1" ],
      about: "Vital.template: DFN, visit string, metric units" }
  ]
}.freeze
