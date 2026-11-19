# frozen_string_literal: true

require "rpms_rpc/api/problem"

# ORQQPL DETAIL (DETAIL^ORQQPL) through Problem.details, as the clinician
# PROVIDER,TEST, on the seeded problem 1 (PROBLEM #9000011, seed patient
# DFN 2) asked for its own patient and for DFN 4, and the raw call for a
# problem not on file, which dies in M. Nothing is filed. rpms-rpc#821.
Problem = RpmsRpc::Problem

CAPTURE = {
  rpc: "ORQQPL DETAIL", entry_point: "DETAIL^ORQQPL",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair; DUZ 200)",
  access: "PROV123", verify: "PROV123!!",
  note: "Run on a throwaway container; every call reads.",
  calls: [
    { name: "unknown_problem", inputs: [ "2", "999999999" ], expect_error: true,
      about: "problem 999999999, not on file: DETAIL^GMPLUTL2 leaves ORGMPL(\"NARRATIVE\") undefined" }
  ],
  flows: {
    "details_seed" => { about: "details of problem 1 for its patient, DFN 2", run: -> { Problem.details(2, 1) } },
    "details_other_patient" => { about: "details of problem 1 for DFN 4, not its patient", run: -> { Problem.details(4, 1) } }
  }
}.freeze
