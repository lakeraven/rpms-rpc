# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/note_template"

# NoteTemplate.boilerplate (GETBOIL^TIUSRVT) and .text (GETTEXT^TIUSRVT,
# BLRPLT^TIUSRVD) on the pinned build. GETTEXT answers ^TMP("TIUBOIL",$J),
# whose 0-node is the word-processing header "^^lines^lines^date^^"
# (TIUSRVD.m:81, :88): text must return only the expanded lines.
class NoteTemplateTextLiveTest < LiveSpec::Test
  PATIENT_NAME_TEMPLATE = 8 # "Patient Name", a stock TIU template object
  DFN = 4                   # DEMO,PATIENT ONE

  def test_boilerplate_is_the_unexpanded_template_text
    assert_equal "|PATIENT NAME|", RpmsRpc::NoteTemplate.boilerplate(PATIENT_NAME_TEMPLATE)
  end

  def test_text_expands_each_line_for_the_patient_and_returns_only_those_lines
    expanded = RpmsRpc::NoteTemplate.text([ "Name: |PATIENT NAME|", "Sex: |PATIENT SEX|" ], dfn: DFN)

    assert_equal "Name: DEMO,PATIENT ONE\nSex: FEMALE", expanded
  end
end
