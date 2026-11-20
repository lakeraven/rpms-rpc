# frozen_string_literal: true

require "rpms_rpc/api/referral"
require "rpms_rpc/api/ddr_fileman"

# One conversation per public RpmsRpc::Referral method that reaches the wire,
# recorded as flows as PROFILE,MD on a fresh throwaway container
# (rpms-rpc#258, #621). Setup files referrals 1 and 2 for demo patient 990002
# with DDR FILER. Each flow keeps what the build answered, an M error
# included: the arguments are the ones referral_test.rb passes, and where the
# routine needs more (BMC ADD REFERRAL's 40 formals) a flow sends them.
Referral = RpmsRpc::Referral

def file_referral(date, number)
  values = { ".01" => date, ".02" => number, ".03" => "990002", ".04" => "N", ".14" => "O", ".15" => "A" }
  rows = values.map { |field, value| { file: "90001", field: field, iens: "+1,", value: value } }
  filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows)
  abort "setup: DDR FILER could not file a referral: #{filed.inspect}" unless filed && filed[:success]
  filed[:iens].fetch(1)
end

# BMC ADD REFERRAL's 40 formals (SETREFRL^BMCRPC2): the date and patient,
# then the given pieces by position, the rest empty.
def add_params(date, dfn, given = {})
  params = [ date, dfn ] + ([ "" ] * 38)
  given.each { |i, value| params[i] = value }
  params
end

FULL = { 2 => "N", 3 => "O", 6 => "CARDIOLOGY CONSULT", 7 => "20", 9 => "1", 33 => "183555005", 34 => "Burns referral" }.freeze

def run(&block) = -> { block.call rescue warn("#{$!.class}: #{$!.message[0, 120]}") }

CAPTURE = {
  rpc: "BMC ADD REFERRAL", entry_point: "SETREFRL^BMCRPC2",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a fresh throwaway container, flows in order. Setup files referrals 1 (11/01/2026) and 2 " \
        "(11/02/2026) for demo patient 990002. 183555005 is the SNOMED concept of the build's first referral purpose.",
  setup: lambda { |session|
    RpmsRpc.configure { |cfg| cfg.client = session }
    iens = [ file_referral("3261101", "9000000000201"), file_referral("3261102", "9000000000202") ]
    abort "setup: expected referrals 1 and 2 on a fresh container, filed #{iens.inspect}" unless iens == %w[1 2]
    RpmsRpc.reset!
    {}
  },
  flows: {
    "for_patient" => { about: "for_patient 990002", run: run { Referral.for_patient(990_002) } },
    "pending" => { about: "pending 11/01/2026 to 11/30/2026",
                   run: run { Referral.pending(from: Date.new(2026, 11, 1), to: Date.new(2026, 11, 30)) } },
    "find" => { about: "find referral 1", run: run { Referral.find("1") } },
    "print" => { about: "print referral 1", run: run { Referral.print("1") } },
    "add" => { about: "add: a referral for demo patient 990003 with every required field",
               run: run { Referral.add(*add_params("11/03/2026", "990003", FULL)) } },
    "add_missing" => { about: "add: only the date and patient", run: run { Referral.add(*add_params("11/03/2026", "990003")) } },
    # Referral.add refuses this frame before sending it (#877), so it goes out
    # raw, under BMCRPC as add binds, to keep the build's answer to it.
    "add_short" => { about: "add: the patient and one more argument, a frame Referral.add now refuses, sent raw",
                     run: run {
                       RpmsRpc::ContextScope.scoped(RpmsRpc.client, Referral::CONTEXT) do
                         RpmsRpc.client.call_rpc("BMC ADD REFERRAL", "990002", "44")
                       end
                     } },
    "update" => { about: "update referral 1 with one argument", run: run { Referral.update("1", "44") } },
    "update_status" => { about: "update_status of referral 1 to A1", run: run { Referral.update_status("1", "A1") } },
    "update_status_missing" => { about: "update_status of IEN 999999, which no referral has",
                                 run: run { Referral.update_status("999999", "A1") } },
    "cancel" => { about: "cancel referral 2", run: run { Referral.cancel("2") } },
    "cancel_missing" => { about: "cancel IEN 999999, which no referral has", run: run { Referral.cancel("999999") } },
    "update_consultation_status" => { about: "update_consultation_status of 7 to COMPLETE",
                                      run: run { Referral.update_consultation_status("7", "COMPLETE") } },
    "purposes" => { about: "purposes", run: run { Referral.purposes } },
    "reference_data" => { about: "reference_data", run: run { Referral.reference_data } },
    "users_providers" => { about: "users_providers", run: run { Referral.users_providers } },
    "providers" => { about: "providers", run: run { Referral.providers } },
    "search_referred_to" => { about: "search_referred_to UNSP for type C (a vendor)", run: run { Referral.search_referred_to("UNSP", "C") } },
    "rcis_templates" => { about: "rcis_templates", run: run { Referral.rcis_templates } },
    "rcis_template_detail" => { about: "rcis_template_detail of template 937", run: run { Referral.rcis_template_detail("937") } },
    "patient_eligibility_status" => { about: "patient_eligibility_status of 990001", run: run { Referral.patient_eligibility_status("990001") } },
    "patient_face_sheet" => { about: "patient_face_sheet of 990001", run: run { Referral.patient_face_sheet("990001") } },
    "patient_health_summary" => { about: "patient_health_summary of 990001, type 7 (ADULT REGULAR)",
                                  run: run { Referral.patient_health_summary("990001", "7") } },
    "health_summary_types" => { about: "health_summary_types", run: run { Referral.health_summary_types } },
    "check_year_site_param" => { about: "check_year_site_param", run: run { Referral.check_year_site_param } },
    "add_c32_print_log" => { about: "add_c32_print_log for referral 1 by 206, a date with no time",
                             run: run { Referral.add_c32_print_log("1", "206", "11/01/2026") } }
  }
}.freeze
