# frozen_string_literal: true

require "rpms_rpc/api/patient"
require "rpms_rpc/api/authentication"

# RpmsRpc::Patient.lookup (AGG LOOKUP PATIENTS, FND^AGGPTLKP) on the build as
# PROFILE,REG (rpms-rpc#619): the parameter order and the reply's columns.
# Reads only. Before the run, on the throwaway container and through stock
# FileMan: ALPHA,AVERY's (DFN 990051) health record number was inactivated,
# the facility's "Add extra IDENTIFIERS to SCAN" (#9009061 field 10) was set
# to YES, which adds the community columns to an all-divisions search, and
# BEACON,DREW (DFN 990028) was made a sensitive record (#38.1).
CAPTURE = {
  rpc: "AGG LOOKUP PATIENTS", entry_point: "FND^AGGPTLKP",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair)",
  access: "PREG123", verify: "PREG123!!",
  note: "Reads only, on a throwaway container where DFN 990051's HRN was inactivated, #9009061 field 10 set " \
        "to YES and DFN 990028 made a sensitive record, all through stock FileMan.",
  calls: [],
  flows: {
    "by_name" => { about: "lookup(\"ALPHA\"): the user's division, active patients",
                   run: -> { RpmsRpc::Patient.lookup("ALPHA") } },
    "by_name_type_n" => { about: "lookup(\"ALPHA\", type: \"N\")", run: -> { RpmsRpc::Patient.lookup("ALPHA", type: "N") } },
    "all_divisions" => { about: "lookup(\"ALPHA\", all_divisions: true)",
                         run: -> { RpmsRpc::Patient.lookup("ALPHA", all_divisions: true) } },
    "include_inactive" => { about: "lookup(\"ALPHA\", include_inactive: true)",
                            run: -> { RpmsRpc::Patient.lookup("ALPHA", include_inactive: true) } },
    "both_flags" => { about: "lookup(\"ALPHA\", all_divisions: true, include_inactive: true)",
                      run: -> { RpmsRpc::Patient.lookup("ALPHA", all_divisions: true, include_inactive: true) } },
    "last_comma_space_first" => { about: "lookup(\"MOUSE, MICKEY M\"): the server normalises \", \"",
                                  run: -> { RpmsRpc::Patient.lookup("MOUSE, MICKEY M") } },
    "no_match" => { about: "lookup(\"NOSUCH, PERSON\")", run: -> { RpmsRpc::Patient.lookup("NOSUCH, PERSON") } },
    "many" => { about: "lookup(\"DEMO\")", run: -> { RpmsRpc::Patient.lookup("DEMO") } },
    "sensitive" => { about: "lookup(\"BEACON\"): DFN 990028, made a sensitive record",
                     run: -> { RpmsRpc::Patient.lookup("BEACON") } },
    "bmx_by_name" => { broker: :bmx, withhold: [ "XUS AV CODE" ],
                       about: "over BMX, which has no global-array read: sign on, then lookup(\"MOUSE\")",
                       run: lambda {
                         RpmsRpc::Authentication.authenticate(access_code: "PREG123", verify_code: "PREG123!!")
                         RpmsRpc::Patient.lookup("MOUSE")
                       } },
    "no_ssn" =>{ about: "lookup(\"USER,TEST\"): a patient with no SSN", run: -> { RpmsRpc::Patient.lookup("USER,TEST") } }
  }
}.freeze
