# frozen_string_literal: true

# BGOVIMM PROFILE, a patient's Immunization Profile, as
# Immunization.text_summary asks for it. rpms-rpc#656.
#
# PROFILE^BGOVIMM2 (BGOVIMM2.m:129-132) is IMMPROF^BIRPC(.RET,DFN,"","")
# (BIRPC.m:219-276). The pinned build's Immunization Register (^BIP) is
# empty, so setup registers demo patient 2 through the stock VueCentric
# write (BGOVIMM SETREG, SETREG^BGOVIMM2 -> ADDPAT^BIPATE). Run on a fresh
# throwaway container.
CAPTURE = {
  rpc: "BGOVIMM PROFILE", entry_point: "PROFILE^BGOVIMM2",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!", context: "CIAV VUECENTRIC",
  note: "Setup adds demo patient 2 to the Immunization Register (BGOVIMM SETREG). The build has no " \
        "ImmServe forecaster, so a registered patient's profile is the package's error 307.",
  setup: lambda { |client|
    reply = client.call_rpc_raw("BGOVIMM SETREG", "2")
    abort "setup: BGOVIMM SETREG did not register patient 2: #{reply.inspect}" unless reply.byteslice(1..) == "\x00".b
  },
  calls: [
    { name: "not_in_register", inputs: [ "4" ],
      about: "demo patient 4, who is not in the Immunization Register: the register message (BIRPC.m:246-254)" },
    { name: "registered_no_profile", inputs: [ "2" ],
      about: "demo patient 2, registered by setup: no profile is produced, so the package reports error 307 (BIRPC.m:271-275, IMMERR^BGOVIMM)" }
  ]
}.freeze
