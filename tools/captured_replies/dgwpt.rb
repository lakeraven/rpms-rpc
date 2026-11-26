# frozen_string_literal: true

require "rpms_rpc/api/dg_patient_select"

# The ADT patient-selection calls, as RpmsRpc::DgPatientSelect sends them
# under CIAV VUECENTRIC, recorded as flows as the front desk clerk test role on
# the panel patient QUEBEC,SAGE (DFN 990017). The selection flows run in
# order and leave her as the clerk's last-selected patient.
D = RpmsRpc::DgPatientSelect
CAPTURE = {
  rpc: "DGWPT SELECT", entry_point: "SELECT^DGWPT",
  signed_on_as: "PROFILE,REG (PREG123, the front desk clerk test role's published demo pair)",
  access: "PREG123", verify: "PREG123!!",
  note: "Run on a throwaway container: DGWPT SELECT records the clerk's last-selected patient.",
  flows: {
    "date_of_death" => { about: "DgPatientSelect.date_of_death(990017)", run: -> { D.date_of_death(990_017) } },
    "sensitivity" => { about: "DgPatientSelect.sensitivity(990017)", run: -> { D.sensitivity(990_017) } },
    "means_test_required" => { about: "DgPatientSelect.means_test_required?(990017)", run: -> { D.means_test_required?(990_017) } },
    "primary_care" => { about: "DgPatientSelect.primary_care(990017)", run: -> { D.primary_care(990_017) } },
    "clinic_date_ranges" => { about: "DgPatientSelect.clinic_date_ranges", run: -> { D.clinic_date_ranges } },
    "select" => { about: "DgPatientSelect.select(990017)", run: -> { D.select(990_017) } },
    "last_selected" => { about: "DgPatientSelect.last_selected after the selection", run: -> { D.last_selected } }
  }
}.freeze
