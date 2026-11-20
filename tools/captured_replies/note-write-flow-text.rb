# frozen_string_literal: true

require "rpms_rpc/api/progress_note"
require "rpms_rpc/wire_capture"

# ProgressNote.update_text on a note filed as PROFILE,MD on the NoteWriteFlow
# inputs (DFN 4, title 248, visit 4), with NoteWriteFlow::NOTE_TEXT, whose
# second line is longer than the wrap width. The flow keeps the TEXT list
# update_text sent, which is the body NoteWriteFlow's read-back must find.
# rpms-rpc#623.
FLOW = RpmsRpc::WireCapture::NoteWriteFlow

CAPTURE = {
  rpc: "TIU SET DOCUMENT TEXT", entry_point: "SETTEXT^TIUSRVPT",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206), the note's author",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a throwaway container: the flow files one unsigned note with synthetic text; its IEN is whatever " \
        "TIU CREATE RECORD returned.",
  flows: {
    "update_text" => {
      about: "create a note, then update_text with NoteWriteFlow::NOTE_TEXT",
      run: lambda do
        client = RpmsRpc.client
        note = client.call_rpc_raw("TIU CREATE RECORD", FLOW::DFN, FLOW::TITLE_IEN, "", "", FLOW::VISIT_IEN).byteslice(2..).to_i
        raise "TIU CREATE RECORD made no note" unless note.positive?

        RpmsRpc::ProgressNote.update_text(note.to_s, FLOW::NOTE_TEXT)
      end
    }
  }
}.freeze
