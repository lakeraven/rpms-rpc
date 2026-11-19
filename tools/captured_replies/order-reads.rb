# frozen_string_literal: true

require "rpms_rpc/api/order"

# The order reads order_test.rb replays: ORWOR RESULT for the seeded order
# (SEEDORD, openrpms#723: order 1, on seed patient DFN 4) asked for its own
# patient and for another, ORWOR ACTION TEXT for that order and for one not
# on file, and the site's ORWOR TSALL list, as the physician PROFILE,MD who
# authored the order. Nothing is filed. rpms-rpc#823, #620.
Order = RpmsRpc::Order

CAPTURE = {
  rpc: "ORWOR RESULT", entry_point: "RESULT^ORWOR",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a throwaway container; every call reads.",
  flows: {
    "result_seed" => { about: "result of order 1 for its patient, DFN 4", run: -> { Order.result(4, 1) } },
    "result_other_patient" => { about: "result of order 1 for DFN 3, not its patient", run: -> { Order.result(3, 1) } },
    "action_text_seed" => { about: "action_text of order 1, on file", run: -> { Order.action_text(1) } },
    "action_text_unknown" => { about: "action_text of order 999999, not on file", run: -> { Order.action_text(999_999) } },
    "all_sheets" => { about: "all_sheets", run: -> { Order.all_sheets } }
  }
}.freeze
