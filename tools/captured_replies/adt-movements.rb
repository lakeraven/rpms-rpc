# frozen_string_literal: true

require "rpms_rpc/api/adt"

# RpmsRpc::Adt.movements read on the build as PROVIDER,TEST (rpms-rpc#747).
# The build ships no inpatient stay (openrpms#1263) and no RPC reaches the ADT
# silent API (openrpms#1231), so before this capture DEMO,PATIENT ONE (DFN 4)
# was given one stay on the throwaway container through stock $$ADD^BDGAPI,
# called in the container exactly as openrpms test/inpatient_adt_build_level.sh
# calls it: admitted to DEMO WARD 101-A, switched to bed 101-B two hours later,
# discharged a day after admission. DFN 990012 has no stay.
CAPTURE = {
  rpc: "DDR LISTER", entry_point: "LISTC^DDR",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair)",
  access: "PROV123", verify: "PROV123!!",
  context: "CIAV VUECENTRIC",
  note: "Run on a throwaway container. Before the run, DFN 4 was admitted, switched bed and discharged there " \
        "through stock $$ADD^BDGAPI (no RPC reaches it; openrpms#1231); the build ships no stay.",
  calls: [],
  flows: {
    "one_stay" => { about: "movements(dfn: 4): one admission, its specialty movement and its discharge",
                    run: -> { RpmsRpc::Adt.movements(dfn: 4) } },
    "no_stay" => { about: "movements(dfn: 990012): a patient never admitted",
                   run: -> { RpmsRpc::Adt.movements(dfn: 990_012) } }
  }
}.freeze
