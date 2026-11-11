# frozen_string_literal: true

require "rpms_rpc/api/coverage"
require "rpms_rpc/api/ddr_fileman"

# What the front desk records and reads back for billing (rpms-ux S-REG-03.1),
# recorded as flows as PROFILE,REG on demo patient 990049, which has no
# coverage on file, in this order: on_file before anything is filed, a
# Medicaid number with its state and dates, a lapsed Medicaid record, Medicare
# Part B with an end date and a private policy with an end date, then on_file
# with all of it. The flows mirror test/live/coverage_on_file_live_test.rb.
# rpms-rpc#619.
Cov = RpmsRpc::Coverage
ON_FILE_DFN = 990_049
ON_FILE_STATE = {} # rubocop:disable Style/MutableConstant

CAPTURE = {
  rpc: "AGG BUILD WINDOW MULTIPLE", entry_point: "MULT^AGGBLDWN",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)",
  access: "PREG123", verify: "PREG123!!",
  note: "Run on a throwaway container. Medicare number 1EG4TE5MK73 is the CMS example MBI; names are synthetic. " \
        "STATE WASHINGTON and insurer VETERANS MEDICAL BENEFIT are the build's own entries.",
  flows: {
    "on_file_none" => { about: "on_file before any coverage is filed", run: -> { Cov.on_file(ON_FILE_DFN) } },
    "add_medicaid" => {
      about: "add_medicaid with a number, the state (STATE WASHINGTON) and an end date",
      run: lambda {
        listed = RpmsRpc::DdrFileman.lister(file: "5", fields: "@;.01", flags: "IP", xref: "B", from: "WASHINGTO",
                                            part: "WASHINGTON", max: "1")
        state = ON_FILE_STATE[:state] = listed.fetch(:entries).first.fetch(:ien)
        RpmsRpc.client.recorded.clear # the state look-up is the flow's set-up, not the add
        ON_FILE_STATE[:medicaid] = Cov.add_medicaid(ON_FILE_DFN, effective_on: "01/01/2026", ends_on: "12/31/2027",
                                                                 number: "ZZ4900001", state_ien: state, coverage: nil)
      }
    },
    "add_medicaid_lapsed" => {
      about: "add_medicaid whose eligibility ended 06/30/2025",
      run: lambda {
        Cov.add_medicaid(ON_FILE_DFN, effective_on: "01/01/2024", ends_on: "06/30/2025", number: "ZZ49LAPSE",
                                      state_ien: ON_FILE_STATE.fetch(:state), coverage: nil)
      }
    },
    "add_medicare" => {
      about: "add_medicare Part B (given as \"b\") with an end date",
      run: lambda {
        Cov.add_medicare(ON_FILE_DFN, name: "ZEPHYR,QUINN", number: "1EG4TE5MK73", effective_on: "01/01/2026",
                                      ends_on: "12/31/2027", part: "b")
      }
    },
    "add_private" => {
      about: "add_private_insurance with VETERANS MEDICAL BENEFIT (insurer 5) and an end date",
      run: lambda {
        Cov.add_private_insurance(ON_FILE_DFN, insurer_ien: 5, policy_holder: "ZEPHYR,QUINN", member_number: "ZZM49",
                                               effective_on: "01/01/2026", ends_on: "12/31/2027")
      }
    },
    "on_file" => { about: "on_file with both Medicaid records, Medicare and the private policy on file",
                   run: -> { Cov.on_file(ON_FILE_DFN) } }
  }
}.freeze
