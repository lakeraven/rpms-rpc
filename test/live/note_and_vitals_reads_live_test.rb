# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/clinical_event"
require "rpms_rpc/api/measurement"
require "rpms_rpc/api/progress_note"

# Three chart reads as the provider, on the pinned build's seed
# (rpms-rpc#347), replacing their wire captures:
#
# - ProgressNote.fetch_text (TIU GET RECORD TEXT): note 1, a signed CLINICAL
#   WARNING of DFN 4, reads back with its header and its body.
# - ClinicalEvent.note_visit_string (ORWPCE NOTEVSTR): the same note's visit
#   string, split into location, date and service category.
# - Measurement.latest (BGOVMSR LAST): DFN 4's most recent vitals, one per
#   type, all from visit 6.
#
# When the seed changes, a spec fails and names what it expected. Reads only.
class NoteAndVitalsReadsLiveTest < LiveSpec::Test
  runs_as :provider

  NOTE_IEN = "1" # a seeded, signed note of DFN 4
  DFN = 4        # DEMO,PATIENT ONE
  VITALS_VISIT = 6
  UNKNOWN_IEN = "999999"
  SEED_CHANGED = "the seed may have changed: is this the pinned build?"

  def test_a_signed_note_reads_back_with_its_header_and_body
    text = RpmsRpc::ProgressNote.fetch_text(NOTE_IEN)

    assert_kind_of String, text, "expected note #{NOTE_IEN}'s text; #{SEED_CHANGED}"
    assert_match(/LOCAL TITLE: CLINICAL WARNING/, text)
    assert_match(/STATUS: COMPLETED/, text)
    assert_includes text.lines.map(&:strip), "PATIENT ON ISOLATION"
  end

  def test_an_unknown_note_has_no_text
    assert_nil RpmsRpc::ProgressNote.fetch_text(UNKNOWN_IEN)
  end

  def test_a_notes_visit_string_names_its_location_date_and_category
    visit = RpmsRpc::ClinicalEvent.note_visit_string(NOTE_IEN)

    assert_equal({ location_ien: 3, datetime_raw: "3260828.0008", service_category: "A" }, visit,
                 "expected note #{NOTE_IEN}'s visit at DEMO IHS CLINIC; #{SEED_CHANGED}")
  end

  def test_an_unknown_note_has_no_visit_string
    assert_nil RpmsRpc::ClinicalEvent.note_visit_string(UNKNOWN_IEN)
  end

  def test_latest_vitals_give_one_reading_per_type
    rows = RpmsRpc::Measurement.latest(DFN)

    assert_kind_of Array, rows, "expected DFN #{DFN}'s vitals; #{SEED_CHANGED}"
    assert_equal rows.map { |r| r[:type] }.uniq, rows.map { |r| r[:type] }, "one reading per type"
    assert_includes rows.map { |r| r[:type] }, "BP"
    rows.each do |r|
      assert_equal VITALS_VISIT, r[:visit_ien], r.inspect
      assert_operator r[:measurement_ien], :>, 0, r.inspect
      refute_empty r[:value].to_s, r.inspect
    end
  end

  def test_latest_vitals_narrow_to_the_types_and_visit_asked_for
    assert_equal [ "BP" ], RpmsRpc::Measurement.latest(DFN, types: %w[BP]).map { |r| r[:type] }
    assert_equal RpmsRpc::Measurement.latest(DFN).size, RpmsRpc::Measurement.latest(DFN, visit_ien: VITALS_VISIT).size
    assert_nil RpmsRpc::Measurement.latest(DFN, visit_ien: 999_999), "no readings on a visit that does not exist"
  end
end
