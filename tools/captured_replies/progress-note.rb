# frozen_string_literal: true

require "rpms_rpc/api/progress_note"

# The TIU calls RpmsRpc::ProgressNote makes, on a note filed in setup as
# PROFILE,MD on the seed patient DFN 4, title 248, visit 4 (the NoteWriteFlow
# inputs), on a throwaway container. rpms-rpc#621.
NOTE_TEXT = "S: cough\nO: afebrile"

def note_text_list(text) = RpmsRpc::ProgressNote.send(:text_list, text, RpmsRpc::ProgressNote::WRAP_WIDTH)

CAPTURE = {
  rpc: "TIU CREATE RECORD", entry_point: "MAKE^TIUSRVP",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206), the note's author",
  access: "PMD123", verify: "PMD123!!",
  personas: {
    rn: { access: "PRN123", verify: "PRN123!!", signed_on_as: "PROFILE,RN (PRN123, a published demo pair), not the author" }
  },
  setup: lambda { |client|
    raw = client.call_rpc_raw("TIU CREATE RECORD", "4", "248", "", "", "4").b
    note = raw.byteslice(2..).to_i
    raise "TIU CREATE RECORD made no note: #{raw.inspect}" unless note.positive?

    { note: note.to_s }
  },
  note: "Setup files one unsigned note; the note IEN is whatever TIU CREATE RECORD returned, and each capture's inputs " \
        "name it. The create capture files a second note. Synthetic text only.",
  calls: [
    { name: "create", inputs: [ "4", "248", "", "", "4" ], about: "create: DFN, title, empty VDT and VLOC, the visit" },
    { name: "lock", rpc: "TIU LOCK RECORD", inputs: ->(s) { [ s[:note] ] }, about: "the author locks the note" },
    { name: "lock_held_elsewhere", as: :rn, rpc: "TIU LOCK RECORD", inputs: ->(s) { [ s[:note] ] },
      about: "another session asks for the lock the author holds" },
    { name: "unlock", rpc: "TIU UNLOCK RECORD", inputs: ->(s) { [ s[:note] ] }, about: "the author releases the lock" },
    { name: "authorize_edit", rpc: "TIU AUTHORIZATION", inputs: ->(s) { [ s[:note], "EDIT RECORD" ] },
      about: "the author asks to edit the unsigned note" },
    { name: "authorize_signature", rpc: "TIU AUTHORIZATION", inputs: ->(s) { [ s[:note], "SIGNATURE" ] },
      about: "the author asks to sign it" },
    { name: "authorize_edit_other_user", as: :rn, rpc: "TIU AUTHORIZATION", inputs: ->(s) { [ s[:note], "EDIT RECORD" ] },
      about: "another user asks to edit it" },
    { name: "set_text", rpc: "TIU SET DOCUMENT TEXT", inputs: ->(s) { [ s[:note], "<NOTE_TEXT as update_text sends it>" ] },
      wire_inputs: ->(_client, s) { [ s[:note], note_text_list(NOTE_TEXT) ] },
      about: "the author sets the text as a HDR and TEXT list" },
    { name: "set_text_flat", rpc: "TIU SET DOCUMENT TEXT", inputs: ->(s) { [ s[:note], NOTE_TEXT ] },
      about: "the same text sent flat, with no HDR node" },
    { name: "get_text", rpc: "TIU GET RECORD TEXT", inputs: ->(s) { [ s[:note] ] }, about: "the note's text, read back" },
    { name: "list_unsigned", rpc: "TIU DOCUMENTS BY CONTEXT", inputs: [ "3", "2", "4" ],
      about: "DFN 4's unsigned progress notes (class 3, context 2)" },
    { name: "list_all_signed", rpc: "TIU DOCUMENTS BY CONTEXT", inputs: [ "3", "1", "4" ],
      about: "DFN 4's signed progress notes (context 1)" },
    { name: "list_by_date_range", rpc: "TIU DOCUMENTS BY CONTEXT", inputs: [ "3", "5", "4", "3260901", "3261231", "206" ],
      about: "context 5, bounded by EARLY and LATE, PERSON PROFILE,MD" }
  ]
}.freeze
