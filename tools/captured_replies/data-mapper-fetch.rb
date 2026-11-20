# frozen_string_literal: true

require "rpms_rpc/api/allergy"

# DataMapper's fetch_one, fetch_many, fetch_scalar and fetch_text through a
# configured client, and the allergy rows a host reads, recorded as flows as
# the clinician PROVIDER,TEST. DFN 2 is the seed patient USER,TEST; DFN 4 is the
# demo patient DEMO,PATIENT ONE. Nothing is filed. rpms-rpc#623.
Mapper = RpmsRpc::DataMapper

CAPTURE = {
  rpc: "ORWPT SELECT", entry_point: "SELECT^ORWPT",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair; DUZ 200)",
  access: "PROV123", verify: "PROV123!!",
  note: "Run on a throwaway container; every call reads.",
  flows: {
    "select" => { about: "patient_select.fetch_one of DFN 2", run: -> { Mapper.patient_select.fetch_one("2", extras: { dfn: 2 }) } },
    "select_unknown" => { about: "patient_select.fetch_one of DFN 999999999, not on file",
                          run: -> { Mapper.patient_select.fetch_one("999999999") } },
    "list_from_demo" => { about: "patient_list.fetch_many from the name DEMO", run: -> { Mapper.patient_list.fetch_many("DEMO", "1") } },
    "list_past_the_end" => { about: "patient_list.fetch_many from ZZZZZ, after every name",
                             run: -> { Mapper.patient_list.fetch_many("ZZZZZ", "1") } },
    "allergies" => { about: "allergy_list.fetch_many of DFN 2", run: -> { Mapper.allergy_list.fetch_many("2") } },
    "allergies_for_patient" => { about: "Allergy.for_patient of DFN 2", run: -> { RpmsRpc::Allergy.for_patient(2) } },
    "sensitive" => { about: "patient_sensitive.fetch_scalar of DFN 2", run: -> { Mapper.patient_sensitive.fetch_scalar("2") } },
    "report_text" => { about: "report_text.fetch_text of the IHS report with HSTYPE 999, not on file, for DFN 4",
                       run: -> { Mapper.report_text.fetch_text("4", "IHS", "999", "", "", "", "") } }
  }
}.freeze
