# frozen_string_literal: true

require "date"
require "rpms_rpc/api/registration"

# The conversations RpmsRpc::Registration's #418 rows have with the build:
# gender identity, sexual orientation, legal sex, MBI and sex, recorded as
# flows. Each flow runs the gem as PROFILE,REG on seed patient DFN 990042 and
# keeps every reply, in order. rpms-rpc#621.
DFN = 990_042
NO_PATIENT = 98_765_432
ROW_DATE = Date.new(2026, 10, 15)
OTHER_DATE = Date.new(2026, 10, 16)
DUPLICATE_DATE = Date.new(2026, 10, 17)
MBI_EFFECTIVE = Date.new(2030, 6, 1)
Reg = RpmsRpc::Registration

def held_by_scheduler
  other = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: Integer(ENV.fetch("BROKER_PORT", "9100")), timeout: 30)
  other.connect
  other.authenticate("PSCH123", "PSCH123!!")
  other.create_context("AGGRPC")
  other.call_rpc_global_array("AGG LOCK PATIENT", DFN.to_s)
  yield
ensure
  other&.call_rpc_global_array("AGG UNLOCK PATIENT", DFN.to_s)
  other&.disconnect
end

CAPTURE = {
  rpc: "DDR FILER", entry_point: "FILEC^DDR3",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)",
  access: "PREG123", verify: "PREG123!!",
  note: "Run on a throwaway container: the flows file rows for DFN 990042 in this order, so each flow's replies " \
        "follow from the ones before. Code IENs are the build's #9999999.104 and #9999999.103 entries " \
        "(7 ASKU, 3 FTM, 9 CIS, 6 OTH; 3 BI, 5 UNK, 4 OTH); legal-sex source 30 is a #9000030 entry. DATE " \
        "ENTERED rows are the capture day's.",
  flows: {
    "gi_new" => { about: "set_gender_identity: a new date, two values", run: -> { Reg.set_gender_identity(DFN, values: [ 7, 3 ], date: ROW_DATE) } },
    "gi_existing" => { about: "set_gender_identity: the same date, values 3 and 9, so 7 is removed and 9 added",
                       run: -> { Reg.set_gender_identity(DFN, values: [ 3, 9 ], date: ROW_DATE) } },
    "gi_other" => { about: "set_gender_identity: a new date, OTH with other text",
                    run: -> { Reg.set_gender_identity(DFN, values: [ 6 ], other: "synthetic other text", date: OTHER_DATE) } },
    "gi_clear_other" => { about: "set_gender_identity: the OTH date rewritten as ASKU, so the other text is cleared",
                          run: -> { Reg.set_gender_identity(DFN, values: [ 7 ], date: OTHER_DATE) } },
    "gi_duplicates" => { about: "set_gender_identity: a new date, the same value twice",
                         run: -> { Reg.set_gender_identity(DFN, values: [ 7, 7 ], date: DUPLICATE_DATE) } },
    "gi_other_text_not_oth" => { about: "set_gender_identity: other text beside a value that is not OTH",
                                 run: -> { Reg.set_gender_identity(DFN, values: [ 7 ], other: "synthetic", date: ROW_DATE) } },
    "gi_unknown_code" => { about: "set_gender_identity: a code IEN the build does not have",
                           run: -> { Reg.set_gender_identity(DFN, values: [ 424_242 ], date: ROW_DATE) } },
    "so_new" => { about: "set_sexual_orientation: a new date, two values", run: -> { Reg.set_sexual_orientation(DFN, values: [ 3, 5 ], date: ROW_DATE) } },
    "so_existing" => { about: "set_sexual_orientation: the same date, 5 and OTH with other text",
                       run: -> { Reg.set_sexual_orientation(DFN, values: [ 5, 4 ], other: "synthetic other text", date: ROW_DATE) } },
    "so_unknown_code" => { about: "set_sexual_orientation: a code IEN the build does not have",
                           run: -> { Reg.set_sexual_orientation(DFN, values: [ 424_242 ], date: ROW_DATE) } },
    "legal_new" => { about: "set_legal_sex: a new date", run: -> { Reg.set_legal_sex(DFN, sex: "F", source: 30, date: ROW_DATE) } },
    "legal_existing" => { about: "set_legal_sex: the same date again, X", run: -> { Reg.set_legal_sex(DFN, sex: "X", source: 30, date: ROW_DATE) } },
    "mbi_new" => { about: "add_mbi: a new effective date with a source, lower case",
                   run: -> { Reg.add_mbi(DFN, mbi: "1eg4te5mk73", effective_date: MBI_EFFECTIVE, source: 1) } },
    "mbi_existing" => { about: "add_mbi: the same effective date with no source, so the source is cleared",
                        run: -> { Reg.add_mbi(DFN, mbi: "1EG4TE5MK73", effective_date: MBI_EFFECTIVE) } },
    "mbis" => { about: "mbis after the two writes", run: -> { Reg.mbis(DFN) } },
    "mbis_no_patient" => { about: "mbis of a DFN with no #9000001 entry",
                           run: -> { Reg.mbis(NO_PATIENT) rescue nil } },
    "sex_change" => { about: "set_sex: M to F, with SSN verification on file and no eligibility rows",
                      run: -> { Reg.set_sex(DFN, "F") } },
    "sex_unchanged" => { about: "set_sex: F again, SSN verification now blank", run: -> { Reg.set_sex(DFN, "F") } },
    "sex_no_patient" => { about: "set_sex of a DFN no patient holds", run: -> { Reg.set_sex(NO_PATIENT, "M") } },
    "sex_lock_held" => { about: "set_sex while another user holds AG's lock on the patient",
                         run: -> { held_by_scheduler { Reg.set_sex(DFN, "M") } } }
  }
}.freeze
