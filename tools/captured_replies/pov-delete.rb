# frozen_string_literal: true

require "rpms_rpc/api/encounter"
require "rpms_rpc/api/pov"
require "rpms_rpc/api/problem"
require "rpms_rpc/fileman_date_parser"

# The BGOVPOV DEL conversations RpmsRpc::Pov.delete has with the build,
# recorded as flows as PROFILE,MD. Setup opens a visit for synthetic demo
# patient DFN 990024, files a problem (major depressive disorder, F32.9) and
# files it as the visit's diagnosis. The flows then refuse a delete named
# with DFN 990025, whose it is not, delete it, and refuse the delete again.
# Run on a fresh throwaway container.
PovDel = RpmsRpc::Pov

DEL_DFN = 990_024
DEL_STATE = {}

CAPTURE = {
  rpc: "BGOVPOV DEL", entry_point: "DEL^BGOVPOV",
  signed_on_as: "PROFILE,MD (PMD123, the provider test role's published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a fresh throwaway container. DFN 990024 and 990025 are synthetic seed patients. " \
        "Setup opens the visit and files the problem and its diagnosis; HOSPITAL LOCATION 6, INSTITUTION 7819, " \
        "F32.9 and SNOMED CT 370143000 are the build's own entries.",
  setup: lambda { |client|
    RpmsRpc.configure { |cfg| cfg.client = client }
    now = RpmsRpc::FilemanDateParser.parse_datetime(Array(client.call_rpc("ORWU DT", "NOW")).first.to_s)
    at = RpmsRpc::FilemanDateParser.format_datetime(now - 3600)
    visit = RpmsRpc::Encounter.create(DEL_DFN, location_ien: 6, datetime: at, service_category: "A", create: 1)
    raise "Encounter.create answered #{visit.inspect}" unless visit[:success]

    problem = RpmsRpc::Problem.add(DEL_DFN, { snomed_ct: "370143000", icd_code: "F32.9", description: "SYNTH CAPTURE POV DELETE",
                                              location_ien: "7819" })
    raise "Problem.add answered #{problem.inspect}" unless problem[:success]

    pov = PovDel.add(DEL_DFN, visit[:visit_ien], "F32.9", narrative: "SYNTH CAPTURE POV DELETE",
                                                         modifiers: { problem_ien: problem[:ien], snomed_ct: "370143000" })
    raise "Pov.add answered #{pov.inspect}" unless pov[:success]

    DEL_STATE.merge!(pov: pov[:ien], problem: problem[:ien])
  },
  flows: {
    "delete_wrong_patient" => { about: "delete: the diagnosis, named with DFN 990025, whose it is not",
                                run: -> { PovDel.delete(990_025, DEL_STATE.fetch(:pov), problem_ien: DEL_STATE.fetch(:problem)) } },
    "delete" => { about: "delete: the diagnosis, with the problem it was filed from",
                  run: -> { PovDel.delete(DEL_DFN, DEL_STATE.fetch(:pov), problem_ien: DEL_STATE.fetch(:problem)) } },
    "delete_again" => { about: "delete: the same diagnosis again, no longer on file",
                        run: -> { PovDel.delete(DEL_DFN, DEL_STATE.fetch(:pov), problem_ien: DEL_STATE.fetch(:problem)) } }
  }
}.freeze
