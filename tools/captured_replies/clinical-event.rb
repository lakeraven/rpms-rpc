# frozen_string_literal: true

require "set"
require "rpms_rpc/api/clinical_event"
require "rpms_rpc/conformance/inventory_lock"
require "rpms_rpc/conformance/build_surface"

# ClinicalEvent's ORWPCE reads, each with the note-patient read
# (TIU GET ALERT INFO) the gem makes first, recorded as PROVIDER,TEST on
# notes 3 and 5 of synthetic DFN 4 and on a location lookup for DFN 990003
# that finds no visit (the inputs of test/fixtures/wire_captures/unmapped/orwpce-*.yml).
# Read only. rpms-rpc#619.
# ClinicalEvent asks the client which RPCs the server serves before each
# read; CiaClient answers that with six DDR LISTER pages of #8994. Here the
# answer is the pinned build's own registry (data/inventories/<tag>), as
# test/rpms_rpc/api/clinical_event_test.rb answers it, so the flows record
# only the reads themselves.
CE = RpmsRpc::ClinicalEvent
ROOT = File.expand_path("../..", __dir__)
TAG = RpmsRpc::Conformance::InventoryLock.load(File.join(ROOT, "data/fingerprints/rpms-ops.lock.yml")).entries.keys.first
SERVED = RpmsRpc::Conformance::BuildSurface.load(File.join(ROOT, "data/inventories", TAG), TAG).names.to_set

def on_the_build
  RpmsRpc.client.define_singleton_method(:served_rpcs) { |names| names.to_set & SERVED }
  yield
end

LOOKUP_VSTR = "6;3260312.09;A"

def refused
  yield
rescue CE::NotePatientMismatchError
  nil
end

CAPTURE = {
  rpc: "ORWPCE GET VISIT", entry_point: "GETVISIT^ORWPCE2",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair)",
  access: "PROV123", verify: "PROV123!!",
  note: "Read only; any container of the pinned build.",
  flows: {
    "visit_for_note_3" => { about: "note 3's visit", run: -> { on_the_build { CE.visit_for_note("3", "4", "") } } },
    "visit_for_note_5" => { about: "note 5's visit", run: -> { on_the_build { CE.visit_for_note("5", "4", "") } } },
    "visit_for_note_lookup" => { about: "no note: a visit looked up by location;date;category, none found",
                                 run: -> { on_the_build { CE.visit_for_note("0", "990003", LOOKUP_VSTR) } } },
    "visit_for_note_other_patient" => { about: "note 3 asked for DFN 5, whose note it is not",
                                        run: -> { on_the_build { refused { CE.visit_for_note("3", "5", "") } } } },
    "has_visit_3" => { about: "note 3: has a visit", run: -> { on_the_build { CE.has_visit?("3", "4", "", "") } } },
    "has_visit_5" => { about: "note 5: has a visit", run: -> { on_the_build { CE.has_visit?("5", "4", "", "") } } },
    "has_visit_lookup" => { about: "no note: lookup by location 6 and date, none found",
                            run: -> { on_the_build { CE.has_visit?("0", "990003", "6", "3260312.09") } } },
    "note_visit_string_3" => { about: "note 3's visit string", run: -> { on_the_build { CE.note_visit_string("3") } } },
    "pce_for_note_3" => { about: "note 3's PCE data", run: -> { on_the_build { CE.pce_for_note("3", "4", "") } } },
    "pce_for_note_5" => { about: "note 5's PCE data", run: -> { on_the_build { CE.pce_for_note("5", "4", "") } } },
    "pce_for_note_lookup" => { about: "no note, no visit: header row only",
                               run: -> { on_the_build { CE.pce_for_note("0", "990003", LOOKUP_VSTR) } } },
    "immunization_types" => { about: "immunization types", run: -> { on_the_build { CE.immunization_types } } },
    "skin_test_types" => { about: "skin test types", run: -> { on_the_build { CE.skin_test_types } } },
    "exam_types" => { about: "exam types", run: -> { on_the_build { CE.exam_types } } },
    "education_topics" => { about: "education topics", run: -> { on_the_build { CE.education_topics } } },
    "health_factor_types" => { about: "health factor types", run: -> { on_the_build { CE.health_factor_types } } }
  }
}.freeze
