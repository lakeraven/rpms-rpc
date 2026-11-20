# frozen_string_literal: true

require "rpms_rpc/api/agg"

# RpmsRpc::Agg's stock AGG wrappers on the build as PROFILE,REG (rpms-rpc#619):
# check_sensitive_patient, send_sensitive_notify, error_screen and edit_check.
# The build ships no sensitive record (openrpms#1270), so before the run
# BEACON,DREW (DFN 990028) was given a DG SECURITY LOG (#38.1) entry at
# SECURITY LEVEL 1 on the throwaway container through stock UPDATE^DIE.
# send_sensitive_notify files a bulletin, so this runs on a throwaway container only.
CAPTURE = {
  rpc: "AGG CHECK SENSITIVE PATIENT", entry_point: "CHK^AGGPTSEN",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair)",
  access: "PREG123", verify: "PREG123!!",
  note: "Run on a throwaway container. Before the run, DFN 990028 was made a sensitive record (#38.1 " \
        "SECURITY LEVEL 1) through stock UPDATE^DIE; the build ships none.",
  calls: [],
  flows: {
    "sensitive" => { about: "check_sensitive_patient for DFN 990028, a sensitive record",
                     run: -> { RpmsRpc::Agg.check_sensitive_patient(dfn: 990_028) } },
    "not_sensitive" => { about: "check_sensitive_patient for DFN 990031",
                         run: -> { RpmsRpc::Agg.check_sensitive_patient(dfn: 990_031) } },
    "not_on_file" => { about: "check_sensitive_patient for DFN 999999999, which no patient has",
                       run: -> { RpmsRpc::Agg.check_sensitive_patient(dfn: 999_999_999) } },
    "notify" => { about: "send_sensitive_notify for DFN 990028",
                  run: -> { RpmsRpc::Agg.send_sensitive_notify(dfn: 990_028) } },
    "notify_not_on_file" => { about: "send_sensitive_notify for DFN 999999999, which no patient has",
                              run: -> { RpmsRpc::Agg.send_sensitive_notify(dfn: 999_999_999) } },
    "error_screen_one" => { about: "error_screen for error 37", run: -> { RpmsRpc::Agg.error_screen(errnum: "37") } },
    "error_screen_all" => { about: "error_screen with no error number",
                            run: -> { RpmsRpc::Agg.error_screen(errnum: "") } },
    "edit_check" => { about: "edit_check for DFN 990031", run: -> { RpmsRpc::Agg.edit_check(dfn: 990_031) } }
  }
}.freeze
