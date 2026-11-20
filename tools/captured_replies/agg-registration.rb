# frozen_string_literal: true

require "rpms_rpc/api/agg"

# RpmsRpc::Agg's registration RPCs on the build as PROFILE,REG (rpms-rpc#619):
# add_patient, update_patient, validate_field, window_values, temporary_hrn
# and available?. The add and update flows file a synthetic patient, so this
# runs on a throwaway container only; the DFN is the one that container
# assigned. available? is also asked as PROFILE,MD, who does not hold AGGRPC.
Agg = RpmsRpc::Agg
NEW = { "AGGPTLNM" => "SYNTHETIC", "AGGPTFNM" => "AGGADD", "AGGPTSEX" => "F", "AGGPTDOB" => "03/05/1902",
        "AGGPTSSN" => "900619001" }.freeze

def added_dfn = $agg_dfn || raise("the add flow did not run first") # rubocop:disable Style/GlobalVars

CAPTURE = {
  rpc: "AGG ADD NEW PATIENT", entry_point: "ADD^AGGPTADD",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair)",
  access: "PREG123", verify: "PREG123!!",
  personas: { md: { access: "PMD123", verify: "PMD123!!", signed_on_as: "PROFILE,MD (PMD123, a published demo pair)" } },
  note: "Run on a throwaway container: the add flows file synthetic patients and the update flows edit one.",
  calls: [],
  flows: {
    "add_ok" => { about: "add_patient: a new synthetic patient through Mini Registration",
                  run: -> { $agg_dfn = Agg.add_patient(params: NEW)[:dfn] } }, # rubocop:disable Style/GlobalVars
    "add_refused" => { about: "add_patient with an empty last name",
                       run: -> { Agg.add_patient(params: { "AGGPTLNM" => "" }) } },
    "add_unknown_window" => { about: "add_patient through a window the build does not have",
                              run: -> { Agg.add_patient(window: "No Such Window", params: NEW) } },
    "add_bad_dob" => { about: "add_patient with a date of birth that is no date (13/45/1900)",
                       run: -> { Agg.add_patient(params: NEW.merge("AGGPTFNM" => "AGGBADDOB", "AGGPTDOB" => "13/45/1900", "AGGPTSSN" => "900619002")) } },
    "update_ok" => { about: "update_patient: the new patient's marital status",
                     run: -> { Agg.update_patient(dfn: added_dfn, params: { "AGGPTMAR" => "NEVER MARRIED" }) } },
    "update_refused" => { about: "update_patient with a parameter the window does not have",
                          run: -> { Agg.update_patient(dfn: added_dfn, params: { "AGGNOSUCH" => "X" }) } },
    "update_not_on_file" => { about: "update_patient for DFN 999999999, which no patient has",
                              run: -> { Agg.update_patient(dfn: 999_999_999, params: { "AGGPTMAR" => "NEVER MARRIED" }) } },
    "update_bad_dob" => { about: "update_patient: the new patient's date of birth to 13/45/1900",
                          run: -> { Agg.update_patient(dfn: added_dfn, params: { "AGGPTDOB" => "13/45/1900" }) } },
    "validate_ssn_taken" => { about: "validate_field: an SSN DFN 990001 already has",
                              run: lambda {
                                Agg.validate_field(window: Agg::NEW_PATIENT_WINDOW,
                                                   params: { "AGGPTSSN" => "666021001", "AGGNOSSN" => "", "DFN" => "" })
                              } },
    "validate_ssn_free" => { about: "validate_field: an SSN no patient has",
                             run: lambda {
                               Agg.validate_field(window: Agg::NEW_PATIENT_WINDOW,
                                                  params: { "AGGPTSSN" => "900619999", "AGGNOSSN" => "", "DFN" => "" })
                             } },
    "validate_no_ssn_reason" => { about: "validate_field: no SSN, reason R",
                                  run: -> { Agg.validate_field(window: Agg::NEW_PATIENT_WINDOW, params: { "AGGNOSSN" => "R" }) } },
    "validate_blank" => { about: "validate_field: SSN and no-SSN reason both blank",
                          run: lambda {
                            Agg.validate_field(window: Agg::NEW_PATIENT_WINDOW, params: { "AGGNOSSN" => "", "AGGPTSSN" => "" })
                          } },
    "window_personal" => { about: "window_values: Personal Detail for DFN 990031",
                           run: -> { Agg.window_values(window: "Personal Detail", dfn: 990_031) } },
    "window_no_patient" => { about: "window_values: Personal Detail for DFN 999999999, which no patient has",
                             run: -> { Agg.window_values(window: "Personal Detail", dfn: 999_999_999) } },
    "window_unknown" => { about: "window_values: a window the build does not have",
                          run: -> { Agg.window_values(window: "No Such Window", dfn: 990_031) } },
    "temp_hrn" => { about: "temporary_hrn for the new patient", run: -> { Agg.temporary_hrn(dfn: added_dfn) } },
    "temp_hrn_no_patient" => { about: "temporary_hrn for DFN 999999999, which no patient has",
                               run: -> { Agg.temporary_hrn(dfn: 999_999_999) } },
    "available" => { about: "available? as PROFILE,REG, who holds AGGRPC", run: -> { Agg.available? } },
    "available_md" => { as: :md, about: "available? as PROFILE,MD, who does not hold AGGRPC",
                        run: -> { Agg.available? } }
  }
}.freeze
