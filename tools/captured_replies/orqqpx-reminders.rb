# frozen_string_literal: true

require "rpms_rpc/api/health_summary"

# ORQQPX REMINDERS LIST and ORQQPX REMINDER DETAIL, as RpmsRpc::HealthSummary
# sends them (rpms-rpc#694): REMIND^ORQQPX and REMDET(ORY,ORPT,ORIEN)^ORQQPX.
# The one-parameter "DFN^IEN" frame the gem used to send is kept as evidence of
# what the build answers it.
CAPTURE = {
  rpc: "ORQQPX REMINDER DETAIL", entry_point: "REMDET^ORQQPX",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Seed patient DFN 4 (synthetic data). Reminder evaluation files nothing.",
  calls: [
    { name: "detail_one_parameter", inputs: [ "4^211" ], expect_error: true,
      about: "the frame reminder_detail used to send: DFN and IEN in one parameter; ORIEN is undefined" }
  ],
  flows: {
    "reminders" => { about: "clinical_reminders for DFN 4",
                     run: -> { RpmsRpc::HealthSummary.clinical_reminders(4) } },
    "detail" => { about: "reminder_detail for DFN 4, reminder 211 (Tobacco Screen)",
                  run: -> { RpmsRpc::HealthSummary.reminder_detail(4, 211) } }
  }
}.freeze
