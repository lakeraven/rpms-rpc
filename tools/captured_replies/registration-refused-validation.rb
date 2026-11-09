# frozen_string_literal: true

require "rpms_rpc/api/agg"

# AG's field check, AGG WINDOW DATA VALIDATION, as Registration.register sends
# it first, from a user who holds no registration context: the broker refuses
# it ("Access denied for remote procedure"). Recorded as PROFILE,MD, a
# clinician, who holds no AGGRPC. rpms-rpc#702.
#
# The frame is the one Agg.validate_field sends for the SSN check of a patient
# with no SSN (reason N), in the AGGRPC context it binds. call_rpc_raw keeps the
# refusal's bytes (call_rpc_global_array would raise before recording them);
# ReplayCiaClient#call_rpc_global_array raises it as the live client does.
SSN_CHECK = { "AGGPTSSN" => "", "AGGNOSSN" => "N", "DFN" => "" }.freeze

CAPTURE = {
  rpc: "AGG WINDOW DATA VALIDATION", entry_point: "VAL^AGGWVAL",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; holds no AGGRPC)",
  access: "PMD123", verify: "PMD123!!",
  note: "The broker refuses the check for a user without AGGRPC; nothing is filed.",
  calls: [
    { name: "ssn_check_refused", context: RpmsRpc::Agg::CONTEXT, expect_error: true,
      inputs: [ RpmsRpc::Agg::NEW_PATIENT_WINDOW, RpmsRpc::Agg.encode_parms(SSN_CHECK) ],
      about: "the SSN field check register sends first, as a user without AGGRPC" }
  ]
}.freeze
