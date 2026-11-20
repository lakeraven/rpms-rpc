# frozen_string_literal: true

require "date"
require "rpms_rpc/api/scheduling_setup"

# The DDR LISTER and DDR FILER conversations SchedulingSetup.add_holiday and
# .remove_holiday have with the build on HOLIDAY (#40.5), recorded as flows as
# PROFILE,MD (rpms-rpc#418, #621). The flows run in order on a throwaway
# container: add 2031-07-04, add it again, add 2031-12-25, remove 2031-07-04,
# remove it again (the next holiday is 2031-12-25), then remove 2031-12-25 and
# remove a date with no holiday after it.
Setup = RpmsRpc::SchedulingSetup
JULY = Date.new(2031, 7, 4)
DECEMBER = Date.new(2031, 12, 25)

CAPTURE = {
  rpc: "DDR FILER", entry_point: "FILEC^DDR3",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a throwaway container, flows in order. The build has no HOLIDAY (#40.5) entry in 2031.",
  flows: {
    "add" => { about: "add_holiday: 2031-07-04, LIVESPEC INDEPENDENCE",
               run: -> { Setup.add_holiday(date: JULY, name: "LIVESPEC INDEPENDENCE") } },
    "add_again" => { about: "add_holiday: 2031-07-04 again, already on file",
                     run: -> { Setup.add_holiday(date: JULY, name: "LIVESPEC INDEPENDENCE") } },
    "add_december" => { about: "add_holiday: 2031-12-25, LIVESPEC WINTER",
                        run: -> { Setup.add_holiday(date: DECEMBER, name: "LIVESPEC WINTER") } },
    "remove" => { about: "remove_holiday: 2031-07-04",
                  run: -> { Setup.remove_holiday(JULY) } },
    "remove_again" => { about: "remove_holiday: 2031-07-04 again; the next holiday on file is 2031-12-25",
                        run: -> { Setup.remove_holiday(JULY) } },
    "remove_december" => { about: "remove_holiday: 2031-12-25",
                           run: -> { Setup.remove_holiday(DECEMBER) } },
    "remove_none_after" => { about: "remove_holiday: 2031-12-26, with no holiday on file after it",
                             run: -> { Setup.remove_holiday(Date.new(2031, 12, 26)) } }
  }
}.freeze
