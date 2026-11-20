# frozen_string_literal: true

require "date"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/patient_application"

# PatientApplication's conversations through DDR LISTER and DDR FILER inside
# AG's edit lock, recorded as flows as PROFILE,REG on synthetic seed patient
# DFN 990010 (rpms-ux S-REG-03.3 to 03.5), as
# test/live/patient_application_live_test.rb walks them. Run on a fresh
# throwaway container: the flows run in this order, and each builds on the
# one before. rpms-rpc#620.
PA = RpmsRpc::PatientApplication
DFN = 990_010
NONE_DFN = 990_011 # a synthetic seed patient with no PATIENT APPLICATIONS entry
TYPE = 1 # MEDICAID FORM 100 (#9000048, openrpms SEEDAPPT)
OBTAINED = Date.new(2026, 11, 10)
SUBMITTED = Date.new(2026, 11, 11)
LATER = Date.new(2026, 11, 12)
APP = {}

# A second session, as the same persona, that takes AG's edit lock on DFN and
# keeps it while the flow runs: AG's lock is per job, so the gem's session is
# refused.
def holding_the_lock
  other = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: Integer(ENV.fetch("BROKER_PORT", "9100")), timeout: 30)
  other.connect
  other.authenticate("PREG123", "PREG123!!")
  other.create_context(RpmsRpc::Agg::CONTEXT)
  other.call_rpc_global_array(RpmsRpc::Agg::LOCK_RPC, DFN.to_s)
  yield
ensure
  other&.disconnect
end

CAPTURE = {
  rpc: "DDR FILER", entry_point: "FILEC^DDR3",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)",
  access: "PREG123", verify: "PREG123!!",
  note: "Run on a fresh throwaway container, flows in order. DFN 990010 is a synthetic seed patient with no " \
        "PATIENT APPLICATIONS entry before the first flow; DFN 990011 has none throughout.",
  flows: {
    "types" => { about: "the application types on #9000048", run: -> { PA.types } },
    "none" => { about: "applications of a patient with no #9000045 entry", run: -> { PA.for_patient(NONE_DFN) } },
    "add_first" => {
      about: "the first application: the patient entry, the application, its submission and the stamp",
      run: -> { APP[:first] = PA.add(DFN, obtained: OBTAINED, type: TYPE, submitted: SUBMITTED, via: "O", received_by: 207)[:application] }
    },
    "add_exists" => { about: "the same date again: AG would select it to edit",
                      run: -> { PA.add(DFN, obtained: OBTAINED, type: TYPE) } },
    "add_type_missing" => { about: "type 999, not on #9000048", run: -> { PA.add(DFN, obtained: LATER, type: 999) } },
    "add_later" => { about: "a later application, under the patient's existing entry",
                     run: -> { PA.add(DFN, obtained: LATER, type: TYPE) } },
    "add_invalid" => {
      about: "what FileMan would refuse: a future date, a bad status, via or reason",
      run: lambda {
        PA.add(DFN, obtained: Date.new(2027, 1, 1), type: TYPE)
        PA.add(DFN, obtained: OBTAINED, type: TYPE, status: "X")
        PA.add(DFN, obtained: OBTAINED, type: TYPE, via: "O")
        PA.add(DFN, obtained: OBTAINED, type: TYPE, submitted: SUBMITTED, reason: "AB")
        PA.add(DFN, obtained: OBTAINED, type: TYPE, submitted: SUBMITTED, reason: "A^B C")
      }
    },
    "add_lock_held" => { about: "another session holds AG's edit lock",
                         run: -> { holding_the_lock { PA.add(DFN, obtained: LATER, type: TYPE) } } },
    "status_approved" => { about: "outcome A on the first application, dated under its submission",
                           run: -> { PA.update_status(DFN, application: APP.fetch(:first), status: "A") } },
    "status_not_found" => { about: "outcome for application 999, which the patient does not have",
                            run: -> { PA.update_status(DFN, application: 999, status: "A") } },
    "applications" => { about: "the patient's applications, read whole", run: -> { PA.for_patient(DFN) } },
    "status_error" => { about: "the later application, which has no submission, entered in error",
                        run: -> { PA.update_status(DFN, application: APP.fetch(:first) + 1, status: "E") } }
  }
}.freeze
