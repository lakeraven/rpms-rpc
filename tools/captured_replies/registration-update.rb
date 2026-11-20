# frozen_string_literal: true

require "date"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/ddr_fileman"

# The conversations RpmsRpc::Registration.update, .record and .pick_list have
# with the build through AG (rpms-rpc#381, #621), recorded as flows as
# PROFILE,REG on seed patient DFN 990031 (EMBER,AVERY, born 03/15/1997). The
# record flows run first, before any update. Each update flow runs under AG's
# lock and files through AGG UPDATE PATIENT, in this order, so each flow's
# replies follow from the ones before. 666101009 is the SSN of seed patient
# DFN 990009.
DFN = 990_031
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

def run(&block) = -> { warn(block.call.inspect) }

CAPTURE = {
  rpc: "AGG UPDATE PATIENT", entry_point: "UPD^AGGPTUPD",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)",
  access: "PREG123", verify: "PREG123!!",
  note: "Run on a fresh throwaway container, flows in order. " \
        "Tribe 204, classification 2 and community 7421 are entries of the build's code files.",
  flows: {
    "record" => { about: "record of DFN 990031", run: run { Reg.record(DFN) } },
    "record_no_patient" => { about: "record of DFN 99999999, which no patient has", run: run { Reg.record(99_999_999) } },
    "pick_marital" => { about: "pick_list of marital statuses from MA", run: run { Reg.pick_list(:marital_status, part: "MA") } },
    "three_windows" => { about: "update: date of birth, home phone, email, tribe and eligibility",
                         run: run {
                           Reg.update(DFN, dob: Date.new(1997, 3, 15), phone_home: "406-555-0101", email: "una@example.test",
                                           tribe: "204", eligibility_status: "direct only")
                         } },
    "one_window" => { about: "update: the work phone alone", run: run { Reg.update(DFN, phone_work: "406-555-0199") } },
    "eligibility" => { about: "update: tribe, classification, eligibility, quantums and enrollment number",
                       run: run {
                         Reg.update(DFN, tribe: "204", classification: "2", eligibility_status: "c", blood_quantum: "1/2",
                                         tribe_quantum: "1/4", enrollment_number: "ZZ4901")
                       } },
    "date_moved" => { about: "update: community 7421 since 05/01/2020, with a home phone",
                      run: run { Reg.update(DFN, community_since: Date.new(2020, 5, 1), community_ien: "7421", phone_home: "406-555-0101") } },
    "clear" => { about: "update: clear the work phone (email nil is not sent)", run: run { Reg.update(DFN, phone_work: "", email: nil) } },
    "lock_held" => { about: "update while another user holds AG's lock on the patient",
                     run: run { held_by_scheduler { Reg.update(DFN, phone_home: "406-555-0101") } } },
    "no_patient" => { about: "update of DFN 99999999, which no patient has", run: run { Reg.update(99_999_999, phone_home: "1") } },
    "personal_detail" => { about: "update: religion 1, employer 1, employment full-time, marital 2",
                           run: run { Reg.update(DFN, religion: "1", employer: "1", employment_status: "full-time", marital_status: "2") } },
    "name" => { about: "update: the name, given in lower case with spaces", run: run { Reg.update(DFN, name: " ember,avery ") } },
    "name_refused" => { about: "update: a name with no comma", run: run { Reg.update(DFN, name: "EMBER AVERY") } },
    "ssn_held" => { about: "update: an SSN another patient holds, with a home phone",
                    run: run { Reg.update(DFN, ssn: "666-10-1009", phone_home: "406-555-0101") } },
    "dob_zip" => { about: "update: date of birth, zip and city", run: run { Reg.update(DFN, dob: Date.new(1997, 3, 15), zip: "59000", city: "ANYWHERE") } }
  }
}.freeze
