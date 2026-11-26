# frozen_string_literal: true

require_relative "live_helper"
require_relative "wire_reads"

# The progress-note reads VueCentric makes on the Notes tab and while a note
# is written, sent with the parameters the client sends in a recorded
# session and checked against TIU DOCUMENT (#8925) and TIU DOCUMENT
# DEFINITION (#8925.1): the patient's signed notes (TIU DOCUMENTS BY
# CONTEXT), a note's title and its print name, the title tests (TIU IS THIS
# A CONSULT?, TIU ISPRF, TIU REQUIRES COSIGNATURE, TIU ONE VISIT NOTE?), the
# signing checks (TIU WAS THIS SAVED?, ORWTIU CHKTXT, TIU GET REQUEST, TIU ID
# CAN ATTACH, TIU ID CAN RECEIVE), the title and object lists (TIU LONG LIST
# OF TITLES, TIU GET LIST OF OBJECTS), a template field (TIU FIELD LOAD) and
# whether a reminder dialog may serve as a template (TIU REM DLG OK AS
# TEMPLATE, BEHOTIU RDLGACC). The TIU RPCs are registered in OR CPRS GUI
# CHART and sent under it. Read only.
class NoteReadsLiveTest < LiveSpec::Test
  include WireReads

  runs_as :provider

  DFN = 4 # DEMO,PATIENT ONE, whose notes the demo build seeds
  PROGRESS_NOTES = 3 # the PROGRESS NOTES class of #8925.1
  COMPLETED = "7" # TIU STATUS (#8925.6) COMPLETED
  PROGRESS_NOTE = 248 # the PROGRESS NOTE title
  CONSULT_TITLE = 246 # TELEHEALTH SCREENING CONSULT, a title of the CONSULTS class
  REMINDER_DIALOG = 747 # the reminder dialog the client tested
  NO_DOCUMENT = 999_999_999

  # CONTEXT^TIUSRVLO with context 1, all signed: IEN^PRINT NAME^REFERENCE
  # DATE^PATIENT^AUTHOR^LOCATION^STATUS^VISIT^... Each row is one of the
  # patient's completed #8925 entries, and every one is listed.
  def test_signed_notes_are_the_patients_completed_documents
    got = chart_rows("TIU DOCUMENTS BY CONTEXT", PROGRESS_NOTES.to_s, "1", DFN.to_s, "0", "0", "0", "0", "D", "1").map { |r| pieces(r) }
    filed = listed("8925", ".01;.02;.05").select { |e| e[:pieces][1] == DFN.to_s && e[:pieces][2] == COMPLETED }
    refute_empty filed, "DFN #{DFN} has completed notes on the demo build"
    assert_equal filed.map { |e| e[:ien].to_s }.sort, got.map(&:first).sort
    got.each do |row|
      title = filed.find { |e| e[:ien].to_s == row[0] }[:pieces][0]
      assert_equal title, value_chart("TIU GET DOCUMENT TITLE", row[0]), "note #{row[0]}'s title is #8925 .01"
      assert_equal value_chart("TIU GET PRINT NAME", title), row[1], "note #{row[0]} is listed by its title's print name"
      assert_equal "completed", row[6]
    end
    dates = got.map { |r| r[2].to_f }
    assert_equal dates.sort.reverse, dates, "newest first (D)"
    assert_includes got.map { |r| r[1] }, "CLINICAL WARNING", "the warning behind DFN #{DFN}'s W"
  end

  def test_a_title_and_its_print_name
    assert_equal "Progress Note", value_chart("TIU GET PRINT NAME", PROGRESS_NOTE.to_s)
    assert_equal "0", value_chart("TIU GET DOCUMENT TITLE", NO_DOCUMENT.to_s), "no document, no title"
  end

  # ISCNSLT^TIUCNSLT (TIUCNSLT.m:81-86): is the title in the CONSULTS class.
  # ISPRFTTL^TIUPRF2: is it a patient record flag title.
  def test_title_class_tests
    assert_equal "1", value_chart("TIU IS THIS A CONSULT?", CONSULT_TITLE.to_s)
    assert_equal "0", value_chart("TIU IS THIS A CONSULT?", PROGRESS_NOTE.to_s)
    assert_equal "0", value_chart("TIU ISPRF", PROGRESS_NOTE.to_s)
    assert_equal "0", value_chart("TIU REQUIRES COSIGNATURE", PROGRESS_NOTE.to_s, "0", client.duz.to_s, fm_today.to_s),
                 "a provider's progress note needs no cosigner"
    visit = pieces(rows("BEHOENCV LIST", DFN.to_s).first)[0]
    assert_equal "0", value_chart("TIU ONE VISIT NOTE?", PROGRESS_NOTE.to_s, DFN.to_s, visit), "a progress note is not one per visit"
  end

  # SAVED^TIUSRVP1 (TIUSRVP1.m:87-), CHKTXT^ORWTIU (ORWTIU.m:79-81),
  # GET1405^TIUSRVR (TIUSRVR.m:85-): a signed note was committed and has
  # text; a progress note answers no consult request; a document not on file
  # says so.
  def test_signing_checks_on_a_completed_note
    note = completed_note
    assert_equal "1", value_chart("TIU WAS THIS SAVED?", note)
    assert_equal "1", value_chart("ORWTIU CHKTXT", note)
    assert_equal "0", value_chart("ORWTIU CHKTXT", NO_DOCUMENT.to_s), "no document, no text"
    assert_equal "-1^No Request found for this document", value_chart("TIU GET REQUEST", note)
    assert_equal "-1^TIU Document does not exist", value_chart("TIU GET REQUEST", NO_DOCUMENT.to_s)
  end

  # CANATTCH^TIUSRVA and CANRCV^TIUSRVA: a completed note neither attaches to
  # nor receives an interdisciplinary entry; the reason names its status.
  def test_a_completed_note_takes_no_interdisciplinary_entry
    note = completed_note
    attach = pieces(value_chart("TIU ID CAN ATTACH", note))
    assert_equal "0", attach[0]
    assert_match(/may not ATTACH this COMPLETED/, attach[1])
    receive = pieces(value_chart("TIU ID CAN RECEIVE", note))
    assert_equal "0", receive[0]
    assert_match(/may not ATTACH AN INTERDISCIPLINARY ENTRY TO this COMPLETED/, receive[1])
  end

  # LONGLIST^TIUSRVD: the class's titles and their synonyms, IEN^NAME, in
  # name order; each IEN is a #8925.1 title (TYPE DOC).
  def test_progress_note_titles_are_titles_of_the_definition_file
    got = chart_rows("TIU LONG LIST OF TITLES", PROGRESS_NOTES.to_s, "", "1", "0").map { |r| pieces(r) }
    refute_empty got
    types = listed("8925.1", ".01;.04").to_h { |e| [ e[:ien].to_s, e[:pieces][1] ] }
    got.each { |ien, name| assert_equal "DOC", types[ien], "#{name} (#{ien}) is a title" }
    assert_includes got, [ "17", "ADVERSE REACTION/ALLERGY" ]
    names = got.map { |r| r[1] }
    assert_equal names.sort, names
  end

  # OBJLST^TIUSRVT: the active objects a template may embed, IEN^NAME^^PRINT
  # NAME; each is a #8925.1 entry of TYPE O.
  def test_template_objects_are_objects_of_the_definition_file
    got = chart_rows("TIU GET LIST OF OBJECTS").map { |r| pieces(r) }
    types = listed("8925.1", ".01;.04").to_h { |e| [ e[:ien].to_s, e[:pieces] ] }
    refute_empty got
    got.each do |ien, name|
      assert_equal [ name, "O" ], types[ien], "object #{ien}"
    end
    assert_includes got.map { |r| r[1] }, "LAST MEASUREMENT LIST"
  end

  # LOAD^TIUSRVF: a template field's IEN, then NAME^TYPE^..., then its
  # items; the PHQ-9 answers are the four the instrument scores.
  def test_template_field_load
    got = chart_rows("TIU FIELD LOAD", "IHS PHQ9 ANSWERS")
    field = listed("8927.1", ".01").find { |e| e[:pieces][0] == "IHS PHQ9 ANSWERS" } || flunk("no IHS PHQ9 ANSWERS on #8927.1")
    assert_equal field[:ien].to_s, got[0]
    assert_equal [ "IHS PHQ9 ANSWERS", "C" ], pieces(got[1])[0, 2], "a combo box"
    items = got.drop(2).map { |r| pieces(r) }
    assert_equal 4, items.size
    assert_equal [ "(0) Not at all", "(1) Several days", "(2) More than half the days", "(3) Nearly every day" ], items.map { |r| r[1].strip }
    assert_empty chart_rows("TIU FIELD LOAD", "NO SUCH FIELD").reject(&:empty?)
  end

  # REMDLGOK^TIUSRVT2 (TIUSRVT2.m:77-84): 1 for a reminder dialog (#801.41)
  # that is not disabled, -1 for none. RDLGACC^BEHOTIU (BEHOTIU.m:60-68):
  # whether the user may open its findings.
  def test_reminder_dialog_as_a_template
    dialog = entry("801.41", REMINDER_DIALOG, ".01;3")
    assert_empty dialog.dig("3", :internal).to_s, "reminder dialog #{REMINDER_DIALOG} is not disabled"
    assert_equal "1", value_chart("TIU REM DLG OK AS TEMPLATE", REMINDER_DIALOG.to_s)
    assert_equal "-1", value_chart("TIU REM DLG OK AS TEMPLATE", NO_DOCUMENT.to_s)
    assert_equal "1", value("BEHOTIU RDLGACC", REMINDER_DIALOG.to_s)
  end

  private

  def value_chart(rpc, *params) = client.with_context(CPRS_CHART) { value(rpc, *params) }

  # One of the patient's completed progress notes.
  def completed_note
    listed("8925", ".01;.02;.05").find { |e| e[:pieces] == [ PROGRESS_NOTE.to_s, DFN.to_s, COMPLETED ] }&.fetch(:ien)&.to_s ||
      flunk("DFN #{DFN} has no completed progress note")
  end
end

# The TIU reads are registered in OR CPRS GUI CHART, which the nurse's and the
# medical assistant's rows do not hold: sent under that option, as the
# provider's spec sends them, each is refused.
class NoteReadsRefusalLiveTest < LiveSpec::Test
  include WireReads

  runs_as :nurse, :medical_assistant

  READS = {
    "TIU DOCUMENTS BY CONTEXT" => [ "3", "1", "4", "0", "0", "0", "0", "D", "1" ],
    "TIU GET DOCUMENT TITLE" => [ "1" ],
    "TIU GET PRINT NAME" => [ "248" ],
    "TIU IS THIS A CONSULT?" => [ "246" ],
    "TIU ISPRF" => [ "248" ],
    "TIU REQUIRES COSIGNATURE" => [ "248", "0", "1", "3261125" ],
    "TIU ONE VISIT NOTE?" => [ "248", "4", "" ],
    "TIU WAS THIS SAVED?" => [ "1" ],
    "ORWTIU CHKTXT" => [ "1" ],
    "TIU GET REQUEST" => [ "1" ],
    "TIU ID CAN ATTACH" => [ "1" ],
    "TIU ID CAN RECEIVE" => [ "1" ],
    "TIU LONG LIST OF TITLES" => [ "3", "", "1", "0" ],
    "TIU GET LIST OF OBJECTS" => [],
    "TIU FIELD LOAD" => [ "IHS PHQ9 ANSWERS" ],
    "TIU REM DLG OK AS TEMPLATE" => [ "747" ]
  }.freeze

  def test_each_note_read_is_refused_without_the_chart_option
    refute role_row.holds?(CPRS_CHART), "#{role}'s row holds #{CPRS_CHART}: this spec no longer describes it"
    READS.each { |rpc, params| assert_chart_refused(rpc, *params) }
  end
end
