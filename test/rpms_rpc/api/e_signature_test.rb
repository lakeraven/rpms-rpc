# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/e_signature"

class ESignatureTest < Minitest::Test
  USER_DUZ  = "301"
  NOTE_IEN  = "5001"
  SIG_CODE  = "secret-code"

  # Broker stub that returns one canned raw response for every RPC —
  # for exercising nil/garbage response paths MockClient can't produce.
  class RawResponseClient
    def initialize(response) = @response = response
    def supports?(*) = true
    def call_rpc(*) = @response
  end

  def teardown
    RpmsRpc.reset!
  end

  def stub_broker_response(response)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = RawResponseClient.new(response) }
  end

  # MockClient keys scalar seeds by the first wire param; encryption is
  # randomized per call, so tests that need a seeded VALIDSIG hit pin the
  # cipher to a fixed output.
  def with_fixed_encryption(value = "ENCRYPTED", &block)
    RpmsRpc::XwbCipher.stub(:encrypt, value, &block)
  end

  # -- validate (ORWU VALIDSIG) ---------------------------------------------

  def test_validate_returns_true_for_known_signature
    with_fixed_encryption do
      RpmsRpc.mock! do |m|
        m.seed_scalar(:tiu_valid_signature, "ENCRYPTED", true)
      end

      assert RpmsRpc::ESignature.validate(USER_DUZ, SIG_CODE)
    end
  end

  def test_validate_sends_one_encrypted_param_and_no_duz
    RpmsRpc.mock!

    RpmsRpc::ESignature.validate(USER_DUZ, SIG_CODE)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWU VALIDSIG" }
    assert_equal 1, call[:params].length, "VALIDSIG(ESOK,X)^ORWU takes one wire param"
    wire = call[:params][0]
    refute_equal SIG_CODE, wire, "signature code must not travel in plaintext"
    refute_includes call[:params], USER_DUZ
    assert_equal SIG_CODE, RpmsRpc::XwbCipher.decrypt(wire),
                 "wire param must be the XWB-encrypted signature code"
  end

  def test_validate_returns_false_for_invalid_args
    refute RpmsRpc::ESignature.validate(nil, SIG_CODE)
    refute RpmsRpc::ESignature.validate(USER_DUZ, "")
  end

  def test_validate_nil_or_garbage_response_returns_false
    stub_broker_response(nil)
    refute RpmsRpc::ESignature.validate(USER_DUZ, SIG_CODE)

    stub_broker_response("-1^NOT AUTHORIZED")
    refute RpmsRpc::ESignature.validate(USER_DUZ, SIG_CODE)
  end

  # -- add (TIU SIGN RECORD) ------------------------------------------------

  def test_add_signs_a_note
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_sign_record, NOTE_IEN, "0")
    end

    result = RpmsRpc::ESignature.add(NOTE_IEN, USER_DUZ, SIG_CODE)
    assert result[:success]
  end

  def test_add_sends_note_ien_and_encrypted_code_only
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_sign_record, NOTE_IEN, "0")
    end

    RpmsRpc::ESignature.add(NOTE_IEN, USER_DUZ, SIG_CODE)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "TIU SIGN RECORD" }
    assert_equal 2, call[:params].length, "SIGN(ERR,TIUDA,TIUX)^TIUSRVP takes two wire params"
    assert_equal NOTE_IEN, call[:params][0]
    refute_equal SIG_CODE, call[:params][1], "signature code must not travel in plaintext"
    assert_equal SIG_CODE, RpmsRpc::XwbCipher.decrypt(call[:params][1])
    refute_includes call[:params], USER_DUZ, "signer is the session DUZ, never a wire param"
  end

  def test_add_cosign_sends_identical_wire_shape
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_sign_record, NOTE_IEN, "0")
    end

    RpmsRpc::ESignature.add(NOTE_IEN, USER_DUZ, SIG_CODE, action: :cosign)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "TIU SIGN RECORD" }
    assert_equal 2, call[:params].length,
                 "sign-vs-cosign is decided server-side; no action code on the wire"
    assert_equal SIG_CODE, RpmsRpc::XwbCipher.decrypt(call[:params][1])
  end

  def test_add_raises_on_unknown_action
    assert_raises(ArgumentError) { RpmsRpc::ESignature.add(NOTE_IEN, USER_DUZ, SIG_CODE, action: :nope) }
    assert_raises(ArgumentError) { RpmsRpc::ESignature.add(NOTE_IEN, USER_DUZ, SIG_CODE, action: :addend) }
  end

  def test_add_result_has_exact_two_key_shape
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_sign_record, NOTE_IEN, "0")
    end

    result = RpmsRpc::ESignature.add(NOTE_IEN, USER_DUZ, SIG_CODE)
    assert_equal %i[success raw], result.keys
    assert_equal "0", result[:raw]
  end

  def test_add_error_string_response_returns_failure_with_raw
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_sign_record, NOTE_IEN, "-1^Invalid signature code")
    end

    result = RpmsRpc::ESignature.add(NOTE_IEN, USER_DUZ, SIG_CODE)
    refute result[:success]
    assert_equal "-1^Invalid signature code", result[:raw]
  end

  def test_add_nil_broker_response_does_not_raise
    stub_broker_response(nil)

    result = RpmsRpc::ESignature.add(NOTE_IEN, USER_DUZ, SIG_CODE)
    assert_equal({ success: false, raw: nil }, result)
  end

  def test_blank_args_return_failure
    refute RpmsRpc::ESignature.add(nil, USER_DUZ, SIG_CODE)[:success]
    refute RpmsRpc::ESignature.add(NOTE_IEN, "0", SIG_CODE)[:success]
    refute RpmsRpc::ESignature.add(NOTE_IEN, USER_DUZ, "")[:success]
  end

  # -- remove (TIU DELETE RECORD) -------------------------------------------

  def test_remove_dispatches_tiu_delete_record_with_reason_and_override_flag
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_delete_record, NOTE_IEN, "0")
    end

    RpmsRpc::ESignature.remove(NOTE_IEN, USER_DUZ, reason: "entered in error")
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "TIU DELETE RECORD" }
    assert_equal [ NOTE_IEN, "entered in error", "0" ], call[:params],
                 "DELETE(ERR,TIUDA,TIURSN,OVRRIDE)^TIUSRVP — IEN, reason, override"
  end

  def test_remove_override_flag_sends_one
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_delete_record, NOTE_IEN, "0")
    end

    RpmsRpc::ESignature.remove(NOTE_IEN, USER_DUZ, reason: "entered in error", override: true)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "TIU DELETE RECORD" }
    assert_equal "1", call[:params][2]
  end

  def test_remove_never_calls_tiu_sign_record
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_delete_record, NOTE_IEN, "0")
    end

    RpmsRpc::ESignature.remove(NOTE_IEN, USER_DUZ, reason: "entered in error")
    refute RpmsRpc.client.received_calls.any? { |c| c[:rpc] == "TIU SIGN RECORD" },
           "signature removal is not a TIU SIGN RECORD action code"
  end

  def test_remove_requires_reason
    refute RpmsRpc::ESignature.remove(NOTE_IEN, USER_DUZ, reason: "")[:success]
    refute RpmsRpc::ESignature.remove(NOTE_IEN, USER_DUZ, reason: nil)[:success]
  end

  def test_remove_nil_broker_response_does_not_raise
    stub_broker_response(nil)

    result = RpmsRpc::ESignature.remove(NOTE_IEN, USER_DUZ, reason: "entered in error")
    assert_equal({ success: false, raw: nil }, result)
  end

  # -- which_action (TIU WHICH SIGNATURE ACTION) ----------------------------

  def test_which_action_maps_signature_string_to_sign
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_which_signature_action, NOTE_IEN, "SIGNATURE")
    end

    assert_equal :sign, RpmsRpc::ESignature.which_action(NOTE_IEN, USER_DUZ)
  end

  def test_which_action_maps_cosignature_string_to_cosign
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_which_signature_action, NOTE_IEN, "COSIGNATURE")
    end

    assert_equal :cosign, RpmsRpc::ESignature.which_action(NOTE_IEN, USER_DUZ)
  end

  def test_which_action_sends_only_the_note_ien
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_which_signature_action, NOTE_IEN, "SIGNATURE")
    end

    RpmsRpc::ESignature.which_action(NOTE_IEN, USER_DUZ)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "TIU WHICH SIGNATURE ACTION" }
    assert_equal [ NOTE_IEN ], call[:params],
                 "WHATACT(TIUY,TIUDA)^TIUSRVA — one wire param; DUZ rides the session"
  end

  def test_which_action_handles_lowercase_and_padded_strings
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_which_signature_action, NOTE_IEN, " signature ")
    end

    assert_equal :sign, RpmsRpc::ESignature.which_action(NOTE_IEN, USER_DUZ)
  end

  def test_which_action_returns_nil_when_no_action_permitted
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_which_signature_action, NOTE_IEN, "")
    end
    assert_nil RpmsRpc::ESignature.which_action(NOTE_IEN, USER_DUZ)
  end

  def test_which_action_returns_nil_for_unknown_or_garbage_response
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_which_signature_action, NOTE_IEN, "-1^NO SUCH DOCUMENT")
    end
    assert_nil RpmsRpc::ESignature.which_action(NOTE_IEN, USER_DUZ)
  end

  def test_which_action_returns_nil_for_invalid_ids
    assert_nil RpmsRpc::ESignature.which_action(nil, USER_DUZ)
    assert_nil RpmsRpc::ESignature.which_action(NOTE_IEN, "0")
  end
end
