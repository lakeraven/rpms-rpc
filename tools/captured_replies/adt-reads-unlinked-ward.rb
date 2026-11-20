# frozen_string_literal: true

# RpmsRpc::Adt.current_location for an inpatient whose ward has no HOSPITAL
# LOCATION link (rpms-rpc#619). Taken on the throwaway container of
# adt-reads.rb, after DFN 990013's admission to DEMO WARD, once that ward's
# HOSPITAL LOCATION FILE POINTER (#42 field 44) was cleared through stock
# FILE^DIE. The build links every ward it ships, so only this edit reaches
# the routine's unlinked branch.
CAPTURE = {
  rpc: "ORWPT INPLOC", entry_point: "INPLOC^ORWPT",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair)",
  access: "PROV123", verify: "PROV123!!",
  context: "CIAV VUECENTRIC",
  note: "Run on the throwaway container of adt-reads.rb, after DEMO WARD's field 44 (HOSPITAL LOCATION FILE " \
        "POINTER) was cleared through stock FILE^DIE; the build links every ward it ships.",
  calls: [
    { name: "inploc_admitted_unlinked_ward", inputs: [ "990013" ],
      about: "ORWPT INPLOC for DFN 990013: admitted to DEMO WARD, whose hospital location link was cleared" }
  ]
}.freeze
