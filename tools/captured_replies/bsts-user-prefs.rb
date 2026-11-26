# frozen_string_literal: true

require "rpms_rpc/api/terminology"

# The signed-on user's BSTS search preferences and the concept-selection
# log, as RpmsRpc::Terminology reads and writes them under BSTSRPC, recorded
# as flows as the provider test role, in order: none saved, a save, the
# saved row read back, a value BSTS refuses, a reset, and none saved again,
# so the run leaves the user as it found them. Then the pick VueCentric
# reports after a selection, which BSTS*2.0*7 builds answer and do not
# queue. rpms-rpc#963.
CAPTURE = {
  rpc: "BSTS SET USER PREFS", entry_point: "SET^BSTSUPRF",
  signed_on_as: "PROFILE,MD (PMD123, the provider test role's published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a throwaway container. The flows run in order and end with the user's preferences reset, " \
        "as they were before the run.",
  context: "BSTSRPC",
  calls: [
    { name: "log_blank_concept", rpc: "BSTS LOG SELECTED CONCEPT", inputs: [ "", "36", "", "" ],
      about: "a blank concept id, which Terminology.record_selection refuses before the wire: SELECT^BSTSRPC1 sets BMXSEC and answers nothing" }
  ],
  flows: {
    "preferences_none" => { about: "Terminology.preferences before any save: none saved",
                            run: -> { RpmsRpc::Terminology.preferences } },
    "save" => { about: "Terminology.update_preferences: synonyms, 100 records, parents and children shown",
                run: -> { RpmsRpc::Terminology.update_preferences(search_type: :synonym, max: 100, parents_children: true) } },
    "preferences_saved" => { about: "Terminology.preferences after the save: the row it filed",
                             run: -> { RpmsRpc::Terminology.preferences } },
    "save_refused" => { about: "Terminology.update_preferences(max: 75): BSTS refuses the count",
                        run: lambda do
                          RpmsRpc::Terminology.update_preferences(max: 75)
                        rescue RpmsRpc::Terminology::BstsError
                          nil
                        end },
    "reset" => { about: "Terminology.delete_preferences: the user's entry deleted",
                 run: -> { RpmsRpc::Terminology.delete_preferences } },
    "preferences_reset" => { about: "Terminology.preferences after the reset: none saved again",
                             run: -> { RpmsRpc::Terminology.preferences } },
    "record_selection" => { about: "Terminology.record_selection of 73211009 (Diabetes mellitus) from SRCH Diabetes",
                        run: -> { RpmsRpc::Terminology.record_selection("73211009", description_id: "121589010", subset: "SRCH Diabetes") } }
  }
}.freeze
