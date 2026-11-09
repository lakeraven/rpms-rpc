# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/e_signature"
require_relative "../captured_replies"

# ESignature reads the replies a fresh rpms-ydb container sent: ORWU VALIDSIG
# (test/fixtures/captured_replies/orwu-validsig.yml) and the TIU signature
# calls on two notes PROFILE,MD filed (e-signature.yml), replayed through
# CiaClient.
class ESignatureTest < Minitest::Test
  SLUG = "e-signature"
  USER_DUZ = "206"
  SIG_CODE = "secret-code"
  VALIDSIG = "ORWU VALIDSIG"
  SIGN = "TIU SIGN RECORD"
  DELETE = "TIU DELETE RECORD"
  WHICH = "TIU WHICH SIGNATURE ACTION"

  # Broker stub that returns one canned raw response for every RPC, for the
  # nil-reply paths no capture holds.
  class RawResponseClient
    def initialize(response) = @response = response
    def call_rpc(*) = @response
  end

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def capture(name) = CapturedReplies.raw(SLUG, name)

  def captured_input(name) = CapturedReplies.file(SLUG).fetch("captures").find { |c| c["name"] == name }.fetch("inputs")

  def stub_broker_response(response)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = RawResponseClient.new(response) }
  end

  # The IENs TIU CREATE RECORD gave the two notes on the capture run.
  def signed_note = captured_input("sign").first
  def unsigned_note = captured_input("delete_unsigned").first

  # -- validate (ORWU VALIDSIG) ---------------------------------------------

  def test_validate_is_true_for_the_stored_code_and_false_for_another
    replay(VALIDSIG => [ CapturedReplies.raw("orwu-validsig", "stored_code") ])
    assert RpmsRpc::ESignature.validate(USER_DUZ, SIG_CODE)

    replay(VALIDSIG => [ CapturedReplies.raw("orwu-validsig", "other_code") ])
    refute RpmsRpc::ESignature.validate(USER_DUZ, SIG_CODE)
  end

  def test_validate_sends_one_encrypted_param_and_no_duz
    client = replay(VALIDSIG => [ CapturedReplies.raw("orwu-validsig", "stored_code") ])

    RpmsRpc::ESignature.validate(USER_DUZ, SIG_CODE)

    assert_equal [ VALIDSIG ], client.rpcs_called
    params = client.calls.first[:params]
    assert_equal 1, params.length, "VALIDSIG(ESOK,X)^ORWU takes one wire param"
    refute_equal SIG_CODE, params.first, "signature code must not travel in plaintext"
    refute_includes params, USER_DUZ
    assert_equal SIG_CODE, RpmsRpc::XwbCipher.decrypt(params.first),
                 "wire param must be the XWB-encrypted signature code"
  end

  def test_validate_returns_false_for_invalid_args_without_a_call
    client = replay({})

    refute RpmsRpc::ESignature.validate(nil, SIG_CODE)
    refute RpmsRpc::ESignature.validate(USER_DUZ, "")
    assert_empty client.calls
  end

  def test_validate_nil_response_returns_false
    stub_broker_response(nil)
    refute RpmsRpc::ESignature.validate(USER_DUZ, SIG_CODE)
  end

  # -- add (TIU SIGN RECORD) ------------------------------------------------

  def test_add_signs_a_note_the_build_answers_zero
    replay(SIGN => [ capture("sign") ])

    assert_equal({ success: true, raw: "0" }, RpmsRpc::ESignature.add(signed_note, USER_DUZ, SIG_CODE))
  end

  # SIGN^TIUSRVP answers a wrong code with the TIU error number and its text.
  def test_add_with_a_wrong_code_is_a_failure_carrying_the_builds_reply
    replay(SIGN => [ capture("sign_wrong_code") ])

    result = RpmsRpc::ESignature.add(signed_note, USER_DUZ, "999999")

    refute result[:success]
    assert_match(/\A89250005\^You have entered an incorrect Electronic Signature Code/, result[:raw])
  end

  def test_add_sends_note_ien_and_encrypted_code_only
    client = replay(SIGN => [ capture("sign") ])

    RpmsRpc::ESignature.add(signed_note, USER_DUZ, SIG_CODE)

    params = client.calls.first[:params]
    assert_equal 2, params.length, "SIGN(ERR,TIUDA,TIUX)^TIUSRVP takes two wire params"
    assert_equal signed_note, params[0]
    refute_equal SIG_CODE, params[1], "signature code must not travel in plaintext"
    assert_equal SIG_CODE, RpmsRpc::XwbCipher.decrypt(params[1])
    refute_includes params, USER_DUZ, "signer is the session DUZ, never a wire param"
  end

  def test_add_cosign_sends_identical_wire_shape
    client = replay(SIGN => [ capture("sign") ])

    RpmsRpc::ESignature.add(signed_note, USER_DUZ, SIG_CODE, action: :cosign)

    params = client.calls.first[:params]
    assert_equal 2, params.length, "sign-vs-cosign is decided server-side; no action code on the wire"
    assert_equal SIG_CODE, RpmsRpc::XwbCipher.decrypt(params[1])
  end

  def test_add_raises_on_unknown_action
    client = replay({})

    assert_raises(ArgumentError) { RpmsRpc::ESignature.add(signed_note, USER_DUZ, SIG_CODE, action: :nope) }
    assert_raises(ArgumentError) { RpmsRpc::ESignature.add(signed_note, USER_DUZ, SIG_CODE, action: :addend) }
    assert_empty client.calls
  end

  def test_add_nil_broker_response_does_not_raise
    stub_broker_response(nil)

    assert_equal({ success: false, raw: nil }, RpmsRpc::ESignature.add(signed_note, USER_DUZ, SIG_CODE))
  end

  def test_blank_args_return_failure_without_a_call
    client = replay({})

    refute RpmsRpc::ESignature.add(nil, USER_DUZ, SIG_CODE)[:success]
    refute RpmsRpc::ESignature.add(signed_note, "0", SIG_CODE)[:success]
    refute RpmsRpc::ESignature.add(signed_note, USER_DUZ, "")[:success]
    assert_empty client.calls
  end

  # -- remove (TIU DELETE RECORD) -------------------------------------------

  def test_remove_deletes_an_unsigned_note
    client = replay(DELETE => [ capture("delete_unsigned") ])

    result = RpmsRpc::ESignature.remove(unsigned_note, USER_DUZ, reason: "entered in error")

    assert_equal({ success: true, raw: "0" }, result)
    assert_equal [ { rpc: DELETE, params: [ unsigned_note, "entered in error", "0" ] } ], client.calls,
                 "DELETE(ERR,TIUDA,TIURSN,OVRRIDE)^TIUSRVP: IEN, reason, override"
  end

  # The build refuses to delete a signed note without an override, with the TIU
  # error number and its text.
  def test_remove_of_a_signed_note_is_a_failure_carrying_the_builds_reply
    replay(DELETE => [ capture("delete_signed") ])

    result = RpmsRpc::ESignature.remove(signed_note, USER_DUZ, reason: "entered in error")

    refute result[:success]
    assert_match(/\A89250003\^You may not DELETE the current document/, result[:raw])
  end

  def test_remove_override_flag_sends_one
    client = replay(DELETE => [ capture("delete_signed") ])

    RpmsRpc::ESignature.remove(signed_note, USER_DUZ, reason: "entered in error", override: true)

    assert_equal "1", client.calls.first[:params][2]
    assert_equal [ DELETE ], client.rpcs_called, "signature removal is not a TIU SIGN RECORD action code"
  end

  def test_remove_requires_reason_without_a_call
    client = replay({})

    refute RpmsRpc::ESignature.remove(signed_note, USER_DUZ, reason: "")[:success]
    refute RpmsRpc::ESignature.remove(signed_note, USER_DUZ, reason: nil)[:success]
    assert_empty client.calls
  end

  def test_remove_nil_broker_response_does_not_raise
    stub_broker_response(nil)

    assert_equal({ success: false, raw: nil }, RpmsRpc::ESignature.remove(signed_note, USER_DUZ, reason: "entered in error"))
  end

  # -- which_action (TIU WHICH SIGNATURE ACTION) ----------------------------

  def test_which_action_is_sign_for_the_unsigned_note
    client = replay(WHICH => [ capture("which_action_unsigned") ])

    assert_equal :sign, RpmsRpc::ESignature.which_action(signed_note, USER_DUZ)
    assert_equal [ { rpc: WHICH, params: [ signed_note ] } ], client.calls,
                 "WHATACT(TIUY,TIUDA)^TIUSRVA: one wire param; DUZ rides the session"
  end

  # Once its author has signed it, the build answers COSIGNATURE for the note.
  def test_which_action_is_cosign_once_the_note_is_signed
    replay(WHICH => [ capture("which_action_signed") ])

    assert_equal :cosign, RpmsRpc::ESignature.which_action(signed_note, USER_DUZ)
  end

  def test_which_action_returns_nil_for_a_nil_reply
    stub_broker_response(nil)

    assert_nil RpmsRpc::ESignature.which_action(signed_note, USER_DUZ)
  end

  def test_which_action_returns_nil_for_invalid_ids_without_a_call
    client = replay({})

    assert_nil RpmsRpc::ESignature.which_action(nil, USER_DUZ)
    assert_nil RpmsRpc::ESignature.which_action(signed_note, "0")
    assert_empty client.calls
  end
end
