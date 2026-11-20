# frozen_string_literal: true

require "rpms_rpc/api/encounter"

# Encounter.open's BEHOENCX GETVISIT, FETCH and CHKVISIT conversation and
# Encounter.create's FETCH, recorded as PROVIDER,TEST on seed patient DFN 2,
# whose visit 1 is at DEMO PRIMARY CARE (#44 IEN 10 on this build), as
# test/live/encounter_visit_live_test.rb walks them. Run on a fresh throwaway
# container: create files a visit. rpms-rpc#619.
Enc = RpmsRpc::Encounter
DFN = 2
CLINIC = 10
AT = "3261110.0900"

CAPTURE = {
  rpc: "BEHOENCX FETCH", entry_point: "FETCH^BEHOENCX",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair)",
  access: "PROV123", verify: "PROV123!!",
  note: "Run on a fresh throwaway container: create files a visit for DFN 2 at #{AT}.",
  flows: {
    "open" => { about: "open visit 1 for DFN 2", run: -> { Enc.open(DFN, 1) } },
    "open_other_patient" => { about: "open visit 1 for DFN 3, whose visit it is not", run: -> { Enc.open(3, 1) } },
    "open_unknown" => { about: "open visit 99999999, not on file", run: -> { Enc.open(DFN, 99_999_999) } },
    "create" => { about: "a visit at DEMO PRIMARY CARE, created if not found",
                  run: -> { Enc.create(DFN, location_ien: CLINIC, datetime: AT, service_category: "A") } },
    "create_found" => { about: "the same visit string with CREATE=0 finds it",
                        run: -> { Enc.create(DFN, location_ien: CLINIC, datetime: AT, service_category: "A", create: 0) } },
    "create_unknown_location" => {
      about: "a visit at #44 IEN 999999, not on file",
      run: -> { Enc.create(DFN, location_ien: 999_999, datetime: AT, service_category: "A") }
    }
  }
}.freeze
