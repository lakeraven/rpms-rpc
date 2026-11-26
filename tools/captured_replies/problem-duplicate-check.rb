# frozen_string_literal: true

require "rpms_rpc/api/problem"

# The BGOPROB2 DUPCHK conversations RpmsRpc::Problem.duplicate_check has with
# the build, and the BGOPROB SET one Problem.add has for a lateralized
# problem, recorded as flows as PROFILE,MD on synthetic demo patient DFN
# 990023. Otitis media (SNOMED CT 65363002) is a concept BSTS prompts
# laterality for. Run on a fresh throwaway container: the flows run in this
# order, and the checks after add_left see the problem it files.
DupProblem = RpmsRpc::Problem

DUP_DFN = 990_023
DUP_LOCATION = "7819" # DEMO IHS CLINIC, the INSTITUTION the build's problems are numbered under
OTITIS = {
  snomed_ct: "65363002", descriptive_ct: "804858018", icd_code: "H66.90",
  description: "Otitis media", location_ien: DUP_LOCATION, laterality: "Left"
}.freeze
DUP_FILED = {} # the IEN add_left files, for the flows after it

CAPTURE = {
  rpc: "BGOPROB2 DUPCHK", entry_point: "DUPCHK^BGOPROB2",
  signed_on_as: "PROFILE,MD (PMD123, the provider test role's published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a fresh throwaway container, flows in order. DFN 990023 is a synthetic seed patient. " \
        "SNOMED CT 65363002 and INSTITUTION 7819 are the build's own entries.",
  flows: {
    "check_new_left" => { about: "check: otitis media, left, on DFN 990023, which holds no problem for it",
                          run: -> { DupProblem.duplicate_check(DUP_DFN, "65363002", laterality: "Left") } },
    "add_left" => { about: "add: otitis media, left, H66.90, its description 804858018, at location 7819",
                    run: -> { DUP_FILED[:ien] = DupProblem.add(DUP_DFN, OTITIS)[:ien] } },
    "check_on_file_left" => { about: "check: otitis media, left, now on file",
                              run: -> { DupProblem.duplicate_check(DUP_DFN, "65363002", laterality: "Left") } },
    "check_right" => { about: "check: otitis media, right, which the left problem does not hold",
                       run: -> { DupProblem.duplicate_check(DUP_DFN, "65363002", laterality: "Right") } },
    "check_unlateralized" => { about: "check: otitis media with no laterality",
                               run: -> { DupProblem.duplicate_check(DUP_DFN, "65363002") } },
    "delete" => { about: "delete: the left problem, reason Entered in error",
                  run: -> { DupProblem.delete(DUP_DFN, DUP_FILED.fetch(:ien), reason: "Entered in error") } },
    "check_after_delete" => { about: "check: otitis media, left, after the delete",
                              run: -> { DupProblem.duplicate_check(DUP_DFN, "65363002", laterality: "Left") } },
    "check_two_maps" => { about: "check: SNOMED CT 421986006, which BSTS maps to two ICD-10-CM codes",
                          run: -> { DupProblem.duplicate_check(DUP_DFN, "421986006") } }
  }
}.freeze
