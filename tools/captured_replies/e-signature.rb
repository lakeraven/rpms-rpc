# frozen_string_literal: true

require "rpms_rpc/api/progress_note"
require "rpms_rpc/xwb_cipher"

# The TIU calls RpmsRpc::ESignature makes (TIU WHICH SIGNATURE ACTION, TIU SIGN
# RECORD, TIU DELETE RECORD), on two notes filed in setup as PROFILE,MD on the
# seed patient DFN 4, title 248, visit 4, on a throwaway container. rpms-rpc#619.
def esig_text_list(text) = RpmsRpc::ProgressNote.send(:text_list, text, RpmsRpc::ProgressNote::WRAP_WIDTH)

def esig_create_note(client)
  raw = client.call_rpc_raw("TIU CREATE RECORD", "4", "248", "", "", "4").b
  note = raw.byteslice(2..).to_i
  raise "TIU CREATE RECORD made no note: #{raw.inspect}" unless note.positive?

  note.to_s
end

CAPTURE = {
  rpc: "TIU SIGN RECORD", entry_point: "SIGN^TIUSRVP",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206), the notes' author",
  access: "PMD123", verify: "PMD123!!",
  setup: lambda { |client|
    signed = esig_create_note(client)
    ack = client.call_rpc_raw("TIU SET DOCUMENT TEXT", signed, esig_text_list("S: cough")).b
    raise "TIU SET DOCUMENT TEXT refused: #{ack.inspect}" unless ack.getbyte(1).zero?

    { signed: signed, unsigned: esig_create_note(client) }
  },
  note: "Setup files two unsigned notes, one with text; each capture's inputs name the IEN TIU CREATE RECORD " \
        "returned. The signature code crosses the wire XWB-encrypted with a random row pair, so it is withheld. " \
        "Synthetic text only.",
  calls: [
    { name: "which_action_unsigned", rpc: "TIU WHICH SIGNATURE ACTION", inputs: ->(s) { [ s[:signed] ] },
      about: "the author asks which signature the unsigned note takes" },
    { name: "sign_wrong_code", inputs: ->(s) { [ s[:signed], "<a code the author does not hold, encrypted; withheld>" ] },
      wire_inputs: ->(_client, s) { [ s[:signed], RpmsRpc::XwbCipher.encrypt("999999") ] },
      about: "the author signs with a code that is not theirs" },
    { name: "sign", inputs: ->(s) { [ s[:signed], "<the author's demo signature code, encrypted; withheld>" ] },
      wire_inputs: ->(_client, s) { [ s[:signed], RpmsRpc::XwbCipher.encrypt("123456") ] },
      about: "the author signs with the code SEEDPERS files for PROFILE,MD" },
    { name: "which_action_signed", rpc: "TIU WHICH SIGNATURE ACTION", inputs: ->(s) { [ s[:signed] ] },
      about: "the same question once the note is signed" },
    { name: "delete_signed", rpc: "TIU DELETE RECORD", inputs: ->(s) { [ s[:signed], "entered in error", "0" ] },
      about: "the author asks to delete the signed note, no override" },
    { name: "delete_unsigned", rpc: "TIU DELETE RECORD", inputs: ->(s) { [ s[:unsigned], "entered in error", "0" ] },
      about: "the author deletes the second, unsigned note" }
  ]
}.freeze
