# frozen_string_literal: true

require "rpms_rpc/api/encounter"

# Encounter.visits' BEHOENCX VISITLST conversation, recorded as PROVIDER,TEST
# on seed patient DFN 2, as test/live/encounter_visits_live_test.rb reads it.
# rpms-rpc#619.
CAPTURE = {
  rpc: "BEHOENCX VISITLST", entry_point: "VISITLST^BEHOENCX",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair)",
  access: "PROV123", verify: "PROV123!!",
  note: "Read only; any container of the pinned build.",
  flows: {
    "visits" => { about: "DFN 2's whole visit history, no appointments", run: -> { RpmsRpc::Encounter.visits(2) } }
  }
}.freeze
