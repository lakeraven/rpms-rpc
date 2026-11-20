# frozen_string_literal: true

require "date"
require "rpms_rpc/api/patient_application"

# PatientApplication's conversations (ORWU DT, AG's edit lock, DDR GETS,
# LISTER and FILER on PATIENT APPLICATIONS #9000045), recorded as flows as
# PROFILE,REG (DUZ 207) on synthetic seed patient DFN 990010, which has no
# application before the first flow, as test/live/patient_application_live_test.rb
# walks them. Type 1 is the build's MEDICAID FORM 100. Run on a fresh
# throwaway container: the flows run in this order, and each builds on the
# one before. rpms-rpc#620.
Applications = RpmsRpc::PatientApplication
DFN = 990_010
OBTAINED = Date.new(2026, 11, 1)
SUBMITTED = Date.new(2026, 11, 2)
EARLIER = Date.new(2026, 10, 1)
FILED = {} # the applications the flows add, for the flows after them

CAPTURE = {
  rpc: "DDR FILER", entry_point: "FILEC^DDR3",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)",
  access: "PREG123", verify: "PREG123!!",
  note: "Run on a fresh throwaway container, flows in order. lock_held holds AG's edit lock on DFN 990010 from " \
        "a second PROFILE,REG session (not recorded) while the recorded one asks.",
  flows: {
    "for_patient_none" => { about: "applications of DFN 990010 before any: no PATIENT APPLICATIONS entry",
                            run: -> { Applications.for_patient(DFN) } },
    "add_type_unknown" => { about: "add with type 999999, not on file",
                            run: -> { Applications.add(DFN, obtained: OBTAINED, type: 999_999) } },
    "add_future" => { about: "add obtained tomorrow on the server's clock: only ORWU DT is read",
                      run: -> { Applications.add(DFN, obtained: Date.new(2026, 11, 21), type: 1) } },
    "add_first" => {
      about: "the first application: obtained 11/1/2026, type 1, submitted 11/2/2026 in person, received by DUZ 207",
      run: lambda {
        FILED[:first] = Applications.add(DFN, obtained: OBTAINED, type: 1, submitted: SUBMITTED, via: "O",
                                              received_by: 207)[:application]
      }
    },
    "add_exists" => { about: "the same date and type again: already on file",
                      run: -> { Applications.add(DFN, obtained: OBTAINED, type: 1) } },
    "add_later" => { about: "another application, obtained 10/1/2026, under the patient's entry",
                     run: -> { FILED[:later] = Applications.add(DFN, obtained: EARLIER, type: 1)[:application] } },
    "status_approved" => { about: "the first application approved: status and a dated status under its submission",
                           run: -> { Applications.update_status(DFN, application: FILED.fetch(:first), status: "A") } },
    "status_in_error" => { about: "the later application, with no submission, entered in error",
                           run: -> { Applications.update_status(DFN, application: FILED.fetch(:later), status: "E") } },
    "status_not_found" => { about: "a status for application 999, which the patient does not have",
                            run: -> { Applications.update_status(DFN, application: 999, status: "A") } },
    "for_patient" => { about: "applications of DFN 990010, read whole", run: -> { Applications.for_patient(DFN) } },
    "lock_held" => {
      about: "add while another session holds AG's edit lock",
      run: lambda {
        holder = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: Integer(ENV.fetch("BROKER_PORT")), timeout: 30)
        holder.connect
        holder.authenticate("PREG123", "PREG123!!")
        RpmsRpc::Agg.editing(dfn: DFN, client: holder) { Applications.add(DFN, obtained: Date.new(2026, 9, 1), type: 1) }
        holder.disconnect
      }
    }
  }
}.freeze
