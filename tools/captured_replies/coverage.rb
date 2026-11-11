# frozen_string_literal: true

require "rpms_rpc/api/coverage"

# The conversations RpmsRpc::Coverage has with the build, recorded as flows as
# PROFILE,REG on demo patient 990048, which has no coverage on file, in this
# order (the BQI reads as the operator): Medicare and Medicaid added, read through BQI, deleted row by row
# (with the guard reads each delete makes first), then a private policy added
# and deleted. Each flow's results feed the next through COVERAGE_STATE.
# rpms-rpc#619.
Cov = RpmsRpc::Coverage
COVERAGE_DFN = 990_048
OTHER_DFN = 990_049
WASHINGTON = "48" # STATE WASHINGTON on the pinned build (coverage-on-file.rb finds it by name)
COVERAGE_STATE = {} # rubocop:disable Style/MutableConstant

CAPTURE = {
  rpc: "AGG UPDATE MEDICARE", entry_point: "UPD^AGGUPMCR",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)",
  access: "PREG123", verify: "PREG123!!",
  personas: {
    sys: { access: "SYS123", verify: "RPMS.000",
           signed_on_as: "SYS123 (the build's operator, MANAGER,SYSTEM): BQIRPC answers only the operator on this build" }
  },
  note: "Run on a throwaway container. Medicare number 1EG4TE5MK73 is the CMS example MBI; names are synthetic. " \
        "Each flow's record and multiple IENs are the ones the flow before it filed.",
  flows: {
    "bqi_none" => { as: :sys, about: "for_patient before any coverage is filed", run: -> { Cov.for_patient(COVERAGE_DFN) } },
    "add_medicare" => {
      about: "add_medicare: header (ROI, name, number, suffix) then the eligibility row",
      run: lambda {
        COVERAGE_STATE[:medicare] = Cov.add_medicare(COVERAGE_DFN, roi_on: "11/01/2026", name: "ZZCOV,MEDICARE",
                                                                   number: "1EG4TE5MK73", suffix: "A",
                                                                   effective_on: "11/01/2026")
      }
    },
    "add_medicaid" => {
      about: "add_medicaid: the record (number, state) then its FULL eligibility row",
      run: lambda {
        COVERAGE_STATE[:medicaid] = Cov.add_medicaid(COVERAGE_DFN, effective_on: "11/01/2026", number: "ZZCOV0001",
                                                                   state_ien: WASHINGTON, coverage: "FULL")
      }
    },
    "bqi_both" => { as: :sys, about: "for_patient with Medicare and Medicaid on file", run: -> { Cov.for_patient(COVERAGE_DFN) } },
    "on_file_both" => { about: "on_file with Medicare and Medicaid on file", run: -> { Cov.on_file(COVERAGE_DFN) } },
    "delete_medicare_record_with_rows" => {
      about: "delete_medicare_record while the eligibility row remains: refused before any delete",
      run: -> { Cov.delete_medicare_record(COVERAGE_DFN) }
    },
    "delete_medicaid_other_patient" => {
      about: "delete_medicaid naming another patient: the ownership read refuses it",
      run: lambda {
        mcd = COVERAGE_STATE.fetch(:medicaid)
        Cov.delete_medicaid(OTHER_DFN, record_ien: mcd[:record_ien], eligibility_mien: mcd[:multiple_ien])
      }
    },
    "delete_medicare" => {
      about: "delete_medicare: the eligibility row the add filed",
      run: -> { Cov.delete_medicare(COVERAGE_DFN, eligibility_mien: COVERAGE_STATE.fetch(:medicare)[:mien]) }
    },
    "delete_medicaid" => {
      about: "delete_medicaid: the eligibility row the add filed",
      run: lambda {
        mcd = COVERAGE_STATE.fetch(:medicaid)
        Cov.delete_medicaid(COVERAGE_DFN, record_ien: mcd[:record_ien], eligibility_mien: mcd[:multiple_ien])
      }
    },
    "delete_medicare_record" => { about: "delete_medicare_record once no eligibility row remains",
                                  run: -> { Cov.delete_medicare_record(COVERAGE_DFN) } },
    "delete_medicare_none" => { about: "delete_medicare once the header is gone",
                                run: -> { Cov.delete_medicare(COVERAGE_DFN, eligibility_mien: "1") } },
    "insurers" => { about: "insurers: the build's insurer list",
                    run: -> { COVERAGE_STATE[:insurer] = Cov.insurers.first[:ien] } },
    "add_private" => {
      about: "add_private_insurance with the first insurer",
      run: lambda {
        Cov.add_private_insurance(COVERAGE_DFN, insurer_ien: COVERAGE_STATE.fetch(:insurer),
                                                                           policy_holder: "ZZCOV,HOLDER",
                                                                           member_number: "ZZ0001",
                                                                           effective_on: "11/01/2026")
      }
    },
    "on_file_private" => {
      about: "on_file with the private policy on file: the policy's record IEN",
      run: -> { COVERAGE_STATE[:private_ien] = Cov.on_file(COVERAGE_DFN)[:private].first[:record_ien] }
    },
    "delete_private_other_patient" => {
      about: "delete_private_insurance naming another patient",
      run: -> { Cov.delete_private_insurance(OTHER_DFN, record_ien: COVERAGE_STATE.fetch(:private_ien)) }
    },
    "delete_private" => {
      about: "delete_private_insurance: the policy the add filed",
      run: -> { Cov.delete_private_insurance(COVERAGE_DFN, record_ien: COVERAGE_STATE.fetch(:private_ien)) }
    },
    "delete_private_again" => {
      about: "delete_private_insurance of the same policy again",
      run: -> { Cov.delete_private_insurance(COVERAGE_DFN, record_ien: COVERAGE_STATE.fetch(:private_ien)) }
    },
    "bqi_after" => { as: :sys, about: "for_patient after every delete", run: -> { Cov.for_patient(COVERAGE_DFN) } }
  }
}.freeze
