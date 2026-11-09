# frozen_string_literal: true

# ORWU DT for the server's today and now, as PROFILE,MD under CIAV VUECENTRIC.
# The container's clock is UTC; the capture was made in a US evening, when the
# workstation's local date was the day before the server's. rpms-rpc#644.
CAPTURE = {
  rpc: "ORWU DT", entry_point: "DT^ORWU",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Captured at 18:3x America/Los_Angeles on the calendar day before the server's date.",
  calls: [
    { name: "today", inputs: [ "T", "TS" ],
      about: "the server's today, as BehavioralHealth asks for it (Orwu.fileman_datetime default flags)" },
    { name: "now", inputs: [ "NOW", "TS" ], about: "the server's now" },
    { name: "not_a_date", inputs: [ "NOTADATE", "TS" ], about: "^%DT's answer to text that is not a date" },
    { name: "refused", inputs: [ "T", "TS" ], context: "AMHGRPC", expect_error: true,
      about: "the same call under AMHGRPC, which does not list ORWU DT: the broker refuses it" }
  ]
}.freeze
