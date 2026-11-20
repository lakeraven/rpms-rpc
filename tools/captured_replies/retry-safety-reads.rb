# frozen_string_literal: true

require "rpms_rpc/api/patient"
require "rpms_rpc/api/allergy"
require "rpms_rpc/api/procedure"

# Three public reads RetrySafety classifies :read, recorded as flows as the
# clinician PROVIDER,TEST on the seed patient DFN 2, so a test can check every
# RPC each one sends against the static resolver and the write-RPC pattern.
# Nothing is filed. rpms-rpc#623.
CAPTURE = {
  rpc: "ORWPT SELECT", entry_point: "SELECT^ORWPT",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair; DUZ 200)",
  access: "PROV123", verify: "PROV123!!",
  note: "Run on a throwaway container; every call reads.",
  flows: {
    "patient_find" => { about: "Patient.find of DFN 2", run: -> { RpmsRpc::Patient.find(2) } },
    "allergy_for_patient" => { about: "Allergy.for_patient of DFN 2", run: -> { RpmsRpc::Allergy.for_patient(2) } },
    "procedure_for_patient" => { about: "Procedure.for_patient of DFN 2", run: -> { RpmsRpc::Procedure.for_patient(2) } }
  }
}.freeze
