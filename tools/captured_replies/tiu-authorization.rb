# frozen_string_literal: true

require "rpms_rpc/api/progress_note"

# TIU AUTHORIZATION (CANDO^TIUSRVA) on an unsigned note, asked by its author
# and by another signed-on user, and the calls update_text makes around it.
# rpms-rpc#614. Setup files an unsigned note as PROFILE,MD on the seed patient
# DFN 4, title 248, visit 4 (the NoteWriteFlow inputs), on a throwaway container.
NOTE_TEXT = "Synthetic progress note text for the authorization capture."

CAPTURE = {
  rpc: "TIU AUTHORIZATION", entry_point: "CANDO^TIUSRVA",
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
  note: "The note IEN is whatever TIU CREATE RECORD returned in setup on a fresh container; each capture's inputs name it.",
  calls: [
    { name: "author_edit", inputs: ->(s) { [ s[:note], "EDIT RECORD" ] },
      about: "the author asks to edit the unsigned note" },
    { name: "author_set_text", rpc: "TIU SET DOCUMENT TEXT", inputs: ->(s) { [ s[:note], "<NOTE_TEXT as update_text sends it>" ] },
      wire_inputs: ->(_client, s) { [ s[:note], RpmsRpc::ProgressNote.send(:text_list, NOTE_TEXT, RpmsRpc::ProgressNote::WRAP_WIDTH) ] },
      about: "the author sets the text, the call update_text makes after an allowed authorization" },
    { name: "other_user_edit", as: :rn, inputs: ->(s) { [ s[:note], "EDIT RECORD" ] },
      about: "another user asks to edit the same unsigned note" },
    { name: "other_user_lock", as: :rn, rpc: "TIU LOCK RECORD", inputs: ->(s) { [ s[:note] ] },
      about: "the other user takes the record lock: the lock is no ownership check" },
    { name: "other_user_unlock", as: :rn, rpc: "TIU UNLOCK RECORD", inputs: ->(s) { [ s[:note] ] },
      about: "and releases it" },
    { name: "no_such_note", inputs: [ "999999", "EDIT RECORD" ], about: "a note IEN that does not exist" },
    { name: "refused", inputs: ->(s) { [ s[:note], "EDIT RECORD" ] }, context: "AMHGRPC", expect_error: true,
      about: "the same call under AMHGRPC, which does not list TIU AUTHORIZATION: the broker refuses it" }
  ]
}.freeze
