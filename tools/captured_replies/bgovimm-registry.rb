# frozen_string_literal: true

require "rpms_rpc/api/immunization_registry"

# The immunization component's registry reads, as RpmsRpc::Immunization sends
# them under CIAV VUECENTRIC, recorded as flows as the provider test role on
# the demo image. Reads only.
I = RpmsRpc::Immunization
CAPTURE = {
  rpc: "BGOVIMM GETCONT", entry_point: "GETCONT^BGOVIMM2",
  signed_on_as: "PROFILE,MD (PMD123, the provider test role's published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Reads only.",
  flows: {
    "contraindications" => { about: "Immunization.contraindications", run: -> { I.contraindications } },
    "state_forecaster_on" => { about: "Immunization.state_forecaster_on?", run: -> { I.state_forecaster_on? } },
    "state_forecast_last_run" => { about: "Immunization.state_forecast_last_run(990001)", run: -> { I.state_forecast_last_run(990_001) } },
    "duplicates_allowed" => { about: "Immunization.duplicates_allowed?(104)", run: -> { I.duplicates_allowed?(104) } },
    "registry_case" => { about: "Immunization.registry_case(990001): not registered", run: -> { I.registry_case(990_001) } }
  }
}.freeze
