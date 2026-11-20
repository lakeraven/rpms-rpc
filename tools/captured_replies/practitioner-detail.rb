# frozen_string_literal: true

require "rpms_rpc/api/practitioner"
require "rpms_rpc/api/ddr_fileman"

# DDR GETS ENTRY DATA on NEW PERSON (#200), as Practitioner.detail reads it,
# as PROVIDER,TEST. PROFILE,MD (DUZ 206) carries the build's synthetic NPI
# 1234567893, release authorized, and DEA AP1234563. Setup gives the other
# two release cases a user of their own: PROFILE,REG (DUZ 207) an NPI with
# AUTHORIZE RELEASE OF NPI (41.97) left empty, and DUZ 1 41.97 "1" with no
# NPI. Run on a throwaway container. rpms-rpc#620.
Practitioner = RpmsRpc::Practitioner

CAPTURE = {
  rpc: "DDR GETS ENTRY DATA", entry_point: "GETSC^DDR2",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair; DUZ 200)",
  access: "PROV123", verify: "PROV123!!",
  note: "Setup files, through DDR FILER under CIAV VUECENTRIC, NPI 1234567893 (the build's own synthetic NPI) " \
        "on DUZ 207 and AUTHORIZE RELEASE OF NPI = 1 on DUZ 1.",
  setup: lambda { |client|
    RpmsRpc.configure { |cfg| cfg.client = client }
    RpmsRpc::ContextScope.scoped(client, Practitioner::FILEMAN_CONTEXT) do
      [ [ "207,", "41.99", "1234567893" ], [ "1,", "41.97", "1" ] ].each do |iens, field, value|
        filed = RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: [ { file: "200", field: field, iens: iens, value: value } ])
        abort "setup: DDR FILER did not file #{field} on #{iens}: #{filed.inspect}" unless filed&.dig(:success)
      end
    end
    RpmsRpc.reset!
    {}
  },
  flows: {
    "detail_full" => { about: "detail of DUZ 206: every field filled, NPI release authorized",
                       run: -> { Practitioner.detail(206) } },
    "detail_empty" => { about: "detail of DUZ 200: every field empty", run: -> { Practitioner.detail(200) } },
    "detail_npi_not_released" => { about: "detail of DUZ 207: an NPI on file, 41.97 empty",
                                   run: -> { Practitioner.detail(207) } },
    "detail_released_no_npi" => { about: "detail of DUZ 1: 41.97 1, no NPI on file",
                                  run: -> { Practitioner.detail(1) } },
    "detail_unknown" => { about: "detail of DUZ 999999, no such user", run: -> { Practitioner.detail(999_999) } }
  }
}.freeze
