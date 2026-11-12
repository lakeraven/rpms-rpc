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

  VISIT_STATUSES = %i[none stand_alone appointment].freeze

  def clinical_event = RpmsRpc::ClinicalEvent

  # -- the note asked for under its own patient -------------------------------

  def test_visit_for_note_answers_for_the_notes_own_patient
    visit = clinical_event.visit_for_note(NOTE_IEN, OWNER_DFN)

    assert visit.nil? || (visit.is_a?(Integer) && visit.positive?),
           "expected nil or a visit IEN for note #{NOTE_IEN}; got #{visit.inspect}"
  end

  def test_has_visit_answers_for_the_notes_own_patient
    assert_includes [ true, false ], clinical_event.has_visit?(NOTE_IEN, OWNER_DFN)
  end

  def test_visit_status_answers_for_the_notes_own_patient
    assert_includes VISIT_STATUSES, clinical_event.visit_status(NOTE_IEN, OWNER_DFN)
  end

  def test_pce_for_note_answers_for_the_notes_own_patient
    bundle = clinical_event.pce_for_note(NOTE_IEN, OWNER_DFN)

    assert bundle.nil? || bundle.is_a?(Hash),
           "expected nil or the PCE bundle for note #{NOTE_IEN}; got #{bundle.class}"
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
