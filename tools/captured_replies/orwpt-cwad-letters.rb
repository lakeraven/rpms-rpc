# frozen_string_literal: true

# ORWPT CWAD (CWAD^ORWPT) as Patient.brief_header sends it, for seed patients
# with and without postings, and the broker's answer for an RPC it does not
# serve, on a throwaway container. rpms-rpc#620.
CAPTURE = {
  rpc: "ORWPT CWAD", entry_point: "CWAD^ORWPT",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Reads only, seed patients (synthetic data). unknown_rpc asks for ORWPT CWADX, a name the build " \
        "does not register, so the broker's not-served refusal is captured as RPMS sends it.",
  calls: [
    { name: "warning_and_allergy", inputs: [ "4" ], about: "DFN 4: WA" },
    { name: "allergy", inputs: [ "2" ], about: "DFN 2: A" },
    { name: "none", inputs: [ "3" ], about: "DFN 3: no postings" },
    { name: "unknown_rpc", rpc: "ORWPT CWADX", inputs: [ "4" ], expect_error: true,
      about: "an RPC the broker does not serve" }
  ]
}.freeze
