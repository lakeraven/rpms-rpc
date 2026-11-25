# frozen_string_literal: true

# BGOVIMM GET with "F", a patient's immunization forecast, as
# Immunization.forecast asks for it. GET^BGOVIMM5 (BGOVIMM5.m:216) calls
# IMMFORC^BIRPC (BIRPC.m:119-200). The demo build ships forecasting switched
# off in its Immunization site parameters, so the package answers its error
# 314 as the one "F" row (BIPATUP.m:49). Reads only.
CAPTURE = {
  rpc: "BGOVIMM GET", entry_point: "GET^BGOVIMM",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!", context: "CIAV VUECENTRIC",
  note: "The build's Immunization site parameters switch forecasting off, so every patient's forecast " \
        "is the package's error 314.",
  calls: [
    { name: "forecasting_disabled", inputs: [ "2^F" ],
      about: "demo patient 2's forecast: the package's error 314, forecasting disabled (BIPATUP.m:49)" },
    { name: "forecasting_disabled_other_patient", inputs: [ "990001^F" ],
      about: "demo patient 990001's forecast: the same error, so it is the site's switch, not the patient" }
  ]
}.freeze
