# frozen_string_literal: true

require "rpms_rpc/api/problem"

# The BGOPROB SET / BGOPROB DEL conversations RpmsRpc::Problem.add, .update and
# .delete have with the build, recorded as flows as PROFILE,MD on synthetic
# demo patient DFN 990055, with DFN 990056 as the other patient. rpms-rpc#527.
# Run on a fresh throwaway container: the flows run in this order, and update
# and delete act on the problem add_new files.
Problem = RpmsRpc::Problem

LOCATION = "7819" # DEMO IHS CLINIC, the INSTITUTION the build's problems are numbered under
DEPRESSION = {
  icd_code: "F32.9", description: "SYNTH CAPTURE DEPRESSION", location_ien: LOCATION,
  status: "Chronic", onset_date: "11/01/2026"
}.freeze
FILED = {} # the IEN add_new files, for the flows after it

CAPTURE = {
  rpc: "BGOPROB SET", entry_point: "SET^BGOPROB",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a fresh throwaway container, flows in order. DFN 990055 and 990056 are synthetic seed patients. " \
        "ICD F32.9 and INSTITUTION 7819 are the build's own entries.",
  flows: {
    "add_new" => { about: "add: F32.9, Chronic, onset 11/01/2026, at location 7819, on DFN 990055",
                   run: -> { FILED[:ien] = Problem.add(990_055, DEPRESSION)[:ien] } },
    "update" => { about: "update: the same problem, status Inactive and a new narrative",
                  run: -> { Problem.update(990_055, FILED.fetch(:ien), DEPRESSION.merge(status: "Inactive", description: "SYNTH CAPTURE EDITED")) } },
    "update_wrong_patient" => { about: "update: the problem, named with DFN 990056, whose it is not",
                                run: -> { Problem.update(990_056, FILED.fetch(:ien), DEPRESSION) } },
    "delete_wrong_patient" => { about: "delete: the problem, named with DFN 990056, whose it is not",
                                run: -> { Problem.delete(990_056, FILED.fetch(:ien), reason: "Entered in error") } },
    "delete" => { about: "delete: the problem, on DFN 990055, reason Entered in error",
                  run: -> { Problem.delete(990_055, FILED.fetch(:ien), reason: "Entered in error") } },
    "delete_not_found" => { about: "delete: problem IEN 999999, not on file",
                            run: -> { Problem.delete(990_055, 999_999, reason: "Entered in error") } },
    "add_no_location" => { about: "add: no location",
                           run: -> { Problem.add(990_055, DEPRESSION.merge(location_ien: nil)) } },
    "add_unknown_patient" => { about: "add: DFN 1999999, not on file",
                               run: -> { Problem.add(1_999_999, DEPRESSION) } },
    "add_unresolved_icd" => { about: "add: ICD code NOTACODE, which the build cannot resolve",
                              run: -> { Problem.add(990_055, DEPRESSION.merge(icd_code: "NOTACODE")) } }
  }
}.freeze
