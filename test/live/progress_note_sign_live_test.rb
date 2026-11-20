# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/progress_note"
require "rpms_rpc/api/e_signature"
require "rpms_rpc/api/ddr_fileman"

# ESignature.add (TIU SIGN RECORD, SIGN^TIUSRVP) on a note the clinician
# filed through ProgressNote.create and update_text, read back from TIU
# DOCUMENT (#8925): STATUS (.05), SIGNATURE DATE/TIME (1501) and SIGNED BY
# (1502). A wrong code is refused with 89250005 and the note stays unsigned
# (rpms-rpc#720). WRITES on a disposable container only.
#
# The spec needs the persona's electronic signature code in RPMS_ESIG (never
# logged; rake report:daily passes <PERSONA>_ESIG, #848). PROVIDER,TEST holds
# the published demo code from openrpms' SEEDPERS (openrpms#1247). Every
# PROV123 run supplies it (README, Running the live specs), so a run without
# it fails and says so, rather than skip and leave signing unproven (#851).
class ProgressNoteSignLiveTest < LiveSpec::Test
  runs_as "PROV123"
  writes!

  # The seed patient, visit and title the TIU wire capture files its note on
  # (WireCapture::NoteWriteFlow): DFN 4, visit 4, PRIMARY CARE PROGRESS NOTE.
  DFN = "4"
  VISIT_IEN = "4"
  TITLE_IEN = "248"
  TIU_DOCUMENT_FILE = "8925"
  # STATUS, SIGNATURE DATE/TIME, SIGNED BY.
  SIGN_FIELDS = ".05;1501;1502"
  # TIU STATUS (#8925.6): 7 COMPLETED once signed, 5 UNSIGNED before.
  STATUS_COMPLETED = "7"
  STATUS_UNSIGNED = "5"
  INCORRECT_CODE = "89250005"

  def test_sign_record_signs_the_clinicians_note_and_reads_back_signed
    esig = signature_code!
    note = file_note!("Synthetic note signed by the live spec.")

    signed = RpmsRpc::ESignature.add(note, client.duz, esig)

    assert signed[:success], "TIU SIGN RECORD refused note #{note}: #{scrub(signed[:raw], esig).inspect}"
    fields = sign_fields(note)
    assert_equal STATUS_COMPLETED, fields.dig(".05", :internal),
                 "note #{note} status after sign: #{fields['.05'].inspect}"
    assert_equal "COMPLETED", fields.dig(".05", :external)
    assert_equal client.duz.to_s, fields.dig("1502", :internal), "SIGNED BY must be the session user"
    assert_match(/\A\d{7}\.\d+\z/, fields.dig("1501", :internal).to_s, "SIGNATURE DATE/TIME must be a FileMan date/time")

    puts "\n#{persona}: note #{note} on DFN #{DFN} signed by DUZ #{fields.dig('1502', :internal)} " \
         "at #{fields.dig('1501', :internal)} (#{fields.dig('.05', :external)})"
  end

  def test_sign_record_refuses_a_wrong_code_and_the_note_stays_unsigned
    esig = signature_code!
    wrong = wrong_code_for(esig)
    note = file_note!("Synthetic note the live spec signs with a wrong code.")

    refused = RpmsRpc::ESignature.add(note, client.duz, wrong)

    refute refused[:success], "a wrong code must not sign note #{note}"
    raw = scrub(refused[:raw], esig, wrong)
    assert raw.start_with?("#{INCORRECT_CODE}^"), "refusal must be #{INCORRECT_CODE}, got #{raw.inspect}"
    assert_match(/incorrect Electronic Signature Code/, raw)
    fields = sign_fields(note)
    assert_equal STATUS_UNSIGNED, fields.dig(".05", :internal),
                 "note #{note} status after a refused sign: #{fields['.05'].inspect}"
    assert_equal "", fields.dig("1502", :internal).to_s, "a refused sign must leave SIGNED BY empty"
    assert_equal "", fields.dig("1501", :internal).to_s, "a refused sign must leave SIGNATURE DATE/TIME empty"
    assert_equal :sign, RpmsRpc::ESignature.which_action(note, client.duz),
                 "the author can still sign the note after a refused code"

    puts "\n#{persona}: wrong code on note #{note} refused (#{raw}); note stays UNSIGNED"
  end

  private

  def signature_code!
    esig = ENV["RPMS_ESIG"].to_s
    flunk "RPMS_ESIG is missing: set it to #{persona}'s electronic signature code (rake report:daily: #{persona}_ESIG)" if esig.strip.empty?
    esig
  end

  # The persona's code with every letter and digit shifted by one, so it is
  # never the persona's own.
  def wrong_code_for(esig)
    wrong = esig.tr("0-9A-Za-z", "1-90B-ZAb-za")
    wrong == esig ? "#{esig}1" : wrong
  end

  # create, then lock / update_text / unlock as a TIU client does.
  def file_note!(text)
    created = RpmsRpc::ProgressNote.create(DFN, VISIT_IEN, TITLE_IEN)
    assert created[:success], "TIU CREATE RECORD answered #{created.inspect}"
    note = created.fetch(:ien).to_s
    assert RpmsRpc::ProgressNote.lock(note), "TIU LOCK RECORD did not hold note #{note}"
    begin
      updated = RpmsRpc::ProgressNote.update_text(note, text)
      assert updated[:success], "update_text on note #{note} answered #{updated.inspect}"
    ensure
      RpmsRpc::ProgressNote.unlock(note)
    end
    assert_equal STATUS_UNSIGNED, sign_fields(note).dig(".05", :internal), "a filed note starts UNSIGNED"
    note
  end

  def sign_fields(note)
    entry = RpmsRpc::DdrFileman.gets_entry(file: TIU_DOCUMENT_FILE, iens: "#{note},", fields: SIGN_FIELDS, flags: "IE")
    refute_nil entry, "DDR GETS on TIU DOCUMENT #{note} gave no reply"
    refute entry[:error], "DDR GETS on TIU DOCUMENT #{note}: #{entry.inspect}"
    entry.fetch(:fields)
  end

  # A failure message never carries a code, even if a reply echoed one.
  def scrub(raw, *codes)
    codes.reduce(raw.to_s) { |text, code| text.gsub(code, "[signature code withheld]") }
  end
end
