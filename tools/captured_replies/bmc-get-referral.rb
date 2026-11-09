# frozen_string_literal: true

# BMC GET REFERRAL, one RCIS REFERRAL (#90001) record, as Referral.find asks
# for it (GTRFBYID^BMCRPC1). Run after test/live/referral_cancel_live_test.rb
# on the same throwaway container: a fresh container has no referral, and that
# spec files a minimal one (referral 1, demo patient 990001) with DDR FILER,
# cancels it and files it ACTIVE again. rpms-rpc#622.
CAPTURE = {
  rpc: "BMC GET REFERRAL", entry_point: "GTRFBYID^BMCRPC1",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!", context: "BMCRPC",
  note: "Reads only. Referral 1 is the minimal one the referral cancel live spec filed (no referral " \
        "number, .02), so LIST^DIC on the C index finds nothing, CRTMSG^BMCRPC4 builds no line and " \
        "GTRFBYID+31 reads ^TMP($J,\"PRNRC\",1) undefined: the broker answers that M error.",
  calls: [
    { name: "m_error", inputs: [ "1" ], expect_error: true,
      about: "referral 1, filed without a referral number: an M error inside GTRFBYID" },
    { name: "no_such_referral", inputs: [ "999999999" ], about: "an IEN no referral has: the routine's message, not a record" }
  ]
}.freeze
