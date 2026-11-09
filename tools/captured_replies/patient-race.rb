# frozen_string_literal: true

require "rpms_rpc/api/patient"

# RpmsRpc::Patient.race, deprecated in favour of Registration.race_ethnicity
# (rpms-rpc#486), read on the build as PROFILE,MD: the DDR GETS ENTRY DATA
# conversation it has for a demo patient with PATIENT (#2) .06 RACE on file
# (DFN 4) and one without (DFN 3). It reads only.
CAPTURE = {
  rpc: "DDR GETS ENTRY DATA", entry_point: "GETSC^DDR2",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "DFN 4 is the only demo patient with .06 RACE on file on this build; DFN 3 has none.",
  flows: {
    "race_on_file" => { about: "Patient.race(4): .06 RACE on file",
                        run: -> { RpmsRpc::Patient.race(4) } },
    "race_blank" => { about: "Patient.race(3): no .06 RACE on file",
                      run: -> { RpmsRpc::Patient.race(3) } }
  }
}.freeze
