# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/e_signature"
require "rpms_rpc/api/ddr_fileman"
require_relative "../captured_replies"

# ESignature.add as the clinician PROVIDER,TEST (PROV123, DUZ 200), replayed
# from e-signature-clinician.yml: a wrong code refused and the note left
# unsigned, then the right code signing it, each read back from TIU DOCUMENT
# (#8925) through DdrFileman. rpms-rpc#720.
class ESignatureClinicianTest < Minitest::Test
  SLUG = "e-signature-clinician"
  USER_DUZ = "200"
  SIG_CODE = "secret-code"
  SIGN = "TIU SIGN RECORD"
  GETS = "DDR GETS ENTRY DATA"

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    RpmsRpc.configure { |cfg| cfg.client = CapturedReplies::ReplayCiaClient.new(script) }
  end

  def capture(name) = CapturedReplies.raw(SLUG, name)

  def note = CapturedReplies.file(SLUG).fetch("captures").find { |c| c["name"] == "sign" }.fetch("inputs").first

  def sign_fields(capture_name)
    replay(GETS => [ capture(capture_name) ])
    RpmsRpc::DdrFileman.gets_entry(file: "8925", iens: "#{note},", fields: ".05;1501;1502", flags: "IE").fetch(:fields)
  end

  def test_a_wrong_code_is_refused_and_the_note_stays_unsigned
    replay(SIGN => [ capture("sign_wrong_code") ])
    result = RpmsRpc::ESignature.add(note, USER_DUZ, SIG_CODE)

    refute result[:success]
    assert_equal "89250005^You have entered an incorrect Electronic Signature Code...Try again!", result[:raw]
    %w[fields_unsigned fields_after_wrong_code].each do |name|
      fields = sign_fields(name)
      assert_equal [ "5", "UNSIGNED" ], fields.fetch(".05").values_at(:internal, :external), name
      assert_equal "", fields.fetch("1501")[:internal].to_s, name
      assert_equal "", fields.fetch("1502")[:internal].to_s, name
    end
  end

  def test_the_right_code_signs_the_note_as_the_session_user
    replay(SIGN => [ capture("sign") ])
    assert_equal({ success: true, raw: "0" }, RpmsRpc::ESignature.add(note, USER_DUZ, SIG_CODE))

    fields = sign_fields("fields_signed")
    assert_equal [ "7", "COMPLETED" ], fields.fetch(".05").values_at(:internal, :external)
    assert_equal [ USER_DUZ, "PROVIDER,TEST" ], fields.fetch("1502").values_at(:internal, :external)
    assert_match(/\A\d{7}\.\d+\z/, fields.fetch("1501")[:internal])
  end
end
