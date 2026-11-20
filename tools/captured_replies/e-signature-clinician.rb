# frozen_string_literal: true

require "rpms_rpc/api/progress_note"
require "rpms_rpc/xwb_cipher"

# TIU SIGN RECORD as the clinician PROVIDER,TEST (PROV123), once openrpms' SEEDPERS gave
# that persona the published demo signature code (openrpms#1247): a wrong code refused, the
# right one signing, and TIU DOCUMENT (#8925) read back before and after. One note filed in
# setup with text on the seed patient DFN 4, title 248, visit 4, on a throwaway container.
# rpms-rpc#720.
def clinician_text_list(text) = RpmsRpc::ProgressNote.send(:text_list, text, RpmsRpc::ProgressNote::WRAP_WIDTH)

# STATUS, SIGNATURE DATE/TIME, SIGNED BY.
def clinician_sign_fields(note) = { "FILE" => "8925", "IENS" => "#{note},", "FIELDS" => ".05;1501;1502", "FLAGS" => "IE" }

CAPTURE = {
  rpc: "TIU SIGN RECORD", entry_point: "SIGN^TIUSRVP",
  signed_on_as: "PROVIDER,TEST (PROV123, the staging demo pair; DUZ 200), the note's author",
  access: "PROV123", verify: "PROV123!!",
  setup: lambda { |client|
    raw = client.call_rpc_raw("TIU CREATE RECORD", "4", "248", "", "", "4").b
    note = raw.byteslice(2..).to_i
    raise "TIU CREATE RECORD made no note: #{raw.inspect}" unless note.positive?

    ack = client.call_rpc_raw("TIU SET DOCUMENT TEXT", note.to_s, clinician_text_list("S: synthetic cough")).b
    raise "TIU SET DOCUMENT TEXT refused: #{ack.inspect}" unless ack.getbyte(1).zero?

    { note: note.to_s }
  },
  note: "Setup files one unsigned note with text; each capture's inputs name the IEN TIU CREATE RECORD " \
        "returned. The signature code crosses the wire XWB-encrypted with a random row pair, so it is withheld. " \
        "Synthetic text only.",
  calls: [
    { name: "fields_unsigned", rpc: "DDR GETS ENTRY DATA", inputs: ->(s) { [ clinician_sign_fields(s[:note]) ] },
      about: "the filed note's status, signature date/time and signer before any sign" },
    { name: "sign_wrong_code", inputs: ->(s) { [ s[:note], "<a code the author does not hold, encrypted; withheld>" ] },
      wire_inputs: ->(_client, s) { [ s[:note], RpmsRpc::XwbCipher.encrypt("234567") ] },
      about: "the author signs with a code that is not theirs" },
    { name: "fields_after_wrong_code", rpc: "DDR GETS ENTRY DATA", inputs: ->(s) { [ clinician_sign_fields(s[:note]) ] },
      about: "the same fields once the wrong code was refused" },
    { name: "sign", inputs: ->(s) { [ s[:note], "<the author's demo signature code, encrypted; withheld>" ] },
      wire_inputs: ->(_client, s) { [ s[:note], RpmsRpc::XwbCipher.encrypt("123456") ] },
      about: "the author signs with the code SEEDPERS files for PROVIDER,TEST" },
    { name: "fields_signed", rpc: "DDR GETS ENTRY DATA", inputs: ->(s) { [ clinician_sign_fields(s[:note]) ] },
      about: "the same fields once the note is signed" }
  ]
}.freeze
