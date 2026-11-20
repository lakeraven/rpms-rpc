# frozen_string_literal: true

require "rpms_rpc/api/dg_sensitive"

# RpmsRpc::DgSensitive.check_access and record_bulletin on the build as
# PROVIDER,TEST (rpms-rpc#619). The build ships no sensitive record, so before
# the run BEACON,DREW (DFN 990028) was given a DG SECURITY LOG (#38.1) entry at
# SECURITY LEVEL 1 on the throwaway container through stock UPDATE^DIE (openrpms#1270).
# record_bulletin files a bulletin, so this runs on a throwaway container only.
CAPTURE = {
  rpc: "DG SENSITIVE RECORD ACCESS", entry_point: "PTSEC^DGSEC4",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair)",
  access: "PROV123", verify: "PROV123!!",
  note: "Run on a throwaway container. Before the run, DFN 990028 was made a sensitive record (#38.1 " \
        "SECURITY LEVEL 1) through stock UPDATE^DIE; the build ships none.",
  calls: [
    { name: "access_no_dfn", inputs: [ "", "1", "" ], context: "OR CPRS GUI CHART",
      about: "DG SENSITIVE RECORD ACCESS with no DFN: the routine's own missing-variable reply" },
    { name: "bulletin_no_dfn", rpc: "DG SENSITIVE RECORD BULLETIN", inputs: [ "", "OR CPRS GUI CHART", "3" ],
      context: "OR CPRS GUI CHART", about: "DG SENSITIVE RECORD BULLETIN with no DFN: the one reply that is not 1" }
  ],
  flows: {
    "not_sensitive" => { about: "check_access for DFN 990031, not a sensitive record",
                         run: -> { RpmsRpc::DgSensitive.check_access(dfn: 990_031, generate_message: 0, option: "") } },
    "sensitive" => { about: "check_access for DFN 990028, a sensitive record, asking for the bulletin",
                     run: lambda {
                       RpmsRpc::DgSensitive.check_access(dfn: 990_028, generate_message: 1, option: "OR CPRS GUI CHART")
                     } },
    "not_on_file" => { about: "check_access for DFN 999999999, which no patient has",
                       run: -> { RpmsRpc::DgSensitive.check_access(dfn: 999_999_999, generate_message: 0, option: "") } },
    "bulletin" => { about: "record_bulletin for DFN 990028, action 3",
                    run: -> { RpmsRpc::DgSensitive.record_bulletin(dfn: 990_028, action: 3, option: "OR CPRS GUI CHART") } },
    "bulletin_not_on_file" => { about: "record_bulletin for DFN 999999999, which no patient has",
                                run: lambda {
                                  RpmsRpc::DgSensitive.record_bulletin(dfn: 999_999_999, action: 3,
                                                                       option: "OR CPRS GUI CHART")
                                } }
  }
}.freeze
