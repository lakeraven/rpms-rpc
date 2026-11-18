# frozen_string_literal: true

# The PHR reads: BEHOCCD PHR (portal access), the immunization reconciliation
# count and the CCD status of a visit's referrals, recorded as flows as the
# clinician PROVIDER,TEST on the seed patient DFN 2 and the panel patient
# DFN 990001. Nothing is filed. rpms-rpc#620.
Phr = RpmsRpc::Phr

CAPTURE = {
  rpc: "BEHOCCD PHR", entry_point: "PHR^BEHOCCD",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair; DUZ 200)",
  access: "PROV123", verify: "PROV123!!",
  note: "Run on a throwaway container; every call reads.",
  flows: {
    "enrollment_seed" => { about: "enrollment_status of DFN 2", run: -> { Phr.enrollment_status(2) } },
    "enrollment_panel" => { about: "enrollment_status of DFN 990001", run: -> { Phr.enrollment_status(990_001) } },
    "enrollment_unknown" => { about: "enrollment_status of DFN 999999999, not on file", run: -> { Phr.enrollment_status(999_999_999) } },
    "counts_unknown" => { about: "counts of DFN 999999999, not on file", run: -> { Phr.counts(999_999_999) } },
    "counts" => { about: "counts of DFN 2", run: -> { Phr.counts(2) } },
    "referrals" => { about: "referrals_for_visits of visits 1 and 2", run: -> { Phr.referrals_for_visits([ 1, 2 ]) } }
  }
}.freeze
