# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/clinical_event"

# The note-keyed PCE reads refuse a note of another patient (#531).
#
# On a positive note IEN, ORWPCE GET VISIT, ORWPCE HASVISIT and ORWPCE PCE4NOTE
# read the visit off the TIU note and ignore DFN, so ClinicalEvent reads the
# note's patient first with TIU GET ALERT INFO (GETALRT^TIUSRVR), under OR CPRS
# GUI CHART, the only option that registers it. On the pinned build that read
# answers "1^4^903" for note 1: a seeded note of DFN 4.
#
# The same note is asked for twice: under its own patient, where each read
# answers as it did before, and under another seeded patient, where each read
# raises and no PCE data comes back. When the seed changes, a spec fails and
# names what it expected; it never skips. These specs read only.
class ClinicalEventNotePatientLiveTest < LiveSpec::Test
  NOTE_IEN = "1"       # a seeded note of DFN 4
  OWNER_DFN = 4        # DEMO,PATIENT ONE
  OTHER_DFN = 990_002  # BRAVO,ALEX, a synthetic seed patient

  # What the pinned build answers for note 1 under DFN 4.
  VISIT_IEN = 4
  VISIT_STRING_FORMAT = /\A\d+;\d{7}(\.\d+)?;[A-Z]\z/ # observed "3;3260828.0008;A"
  SEED_CHANGED = "the seed may have changed: is this the pinned build?"

  def clinical_event = RpmsRpc::ClinicalEvent

  # -- the note asked for under its own patient -------------------------------

  def test_visit_for_note_answers_for_the_notes_own_patient
    assert_equal VISIT_IEN, clinical_event.visit_for_note(NOTE_IEN, OWNER_DFN),
                 "expected visit #{VISIT_IEN} for note #{NOTE_IEN}; #{SEED_CHANGED}"
  end

  def test_has_visit_answers_for_the_notes_own_patient
    assert_equal true, clinical_event.has_visit?(NOTE_IEN, OWNER_DFN),
                 "expected note #{NOTE_IEN} to have a visit; #{SEED_CHANGED}"
  end

  def test_visit_status_answers_for_the_notes_own_patient
    assert_equal :stand_alone, clinical_event.visit_status(NOTE_IEN, OWNER_DFN),
                 "expected a stand-alone visit for note #{NOTE_IEN}; #{SEED_CHANGED}"
  end

  def test_pce_for_note_answers_for_the_notes_own_patient
    bundle = clinical_event.pce_for_note(NOTE_IEN, OWNER_DFN)

    assert_kind_of Hash, bundle, "expected the PCE bundle for note #{NOTE_IEN}; #{SEED_CHANGED}"
    header = bundle[:header]
    assert_kind_of Hash, header, "expected a header in the PCE bundle for note #{NOTE_IEN}; #{SEED_CHANGED}"
    assert_match VISIT_STRING_FORMAT, header[:visit_string].to_s,
                 "expected a visit string in the PCE header for note #{NOTE_IEN}; #{SEED_CHANGED}"
  end

  # -- the same note asked for under another patient --------------------------

  def test_visit_for_note_refuses_the_note_under_another_patient
    assert_refused { clinical_event.visit_for_note(NOTE_IEN, OTHER_DFN) }
  end

  def test_has_visit_refuses_the_note_under_another_patient
    assert_refused { clinical_event.has_visit?(NOTE_IEN, OTHER_DFN) }
  end

  def test_visit_status_refuses_the_note_under_another_patient
    assert_refused { clinical_event.visit_status(NOTE_IEN, OTHER_DFN) }
  end

  def test_pce_for_note_refuses_the_note_under_another_patient
    assert_refused { clinical_event.pce_for_note(NOTE_IEN, OTHER_DFN) }
  end

  private

  def assert_refused(&read)
    error = assert_raises(RpmsRpc::ClinicalEvent::NotePatientMismatchError) { read.call }

    assert_equal :mismatch, error.reason,
                 "note #{NOTE_IEN} should be a note of DFN #{OWNER_DFN}: is this the pinned build?"
  end
end
