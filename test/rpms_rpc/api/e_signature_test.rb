# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/e_signature"

class ESignatureTest < Minitest::Test
  USER_DUZ  = "301"
  NOTE_IEN  = "5001"
  SIG_CODE  = "secret-code"

  def teardown
    RpmsRpc.reset!
  end

  def test_validate_returns_true_for_known_signature
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_valid_signature, USER_DUZ, true)
    end

    assert RpmsRpc::ESignature.validate(USER_DUZ, SIG_CODE)
  end

  def test_validate_dispatches_orwu_validsig
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_valid_signature, USER_DUZ, true)
    end

    RpmsRpc::ESignature.validate(USER_DUZ, SIG_CODE)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWU VALIDSIG" }
    assert_equal [ USER_DUZ, SIG_CODE ], call[:params]
  end

  def test_validate_returns_false_for_invalid_args
    refute RpmsRpc::ESignature.validate(nil, SIG_CODE)
    refute RpmsRpc::ESignature.validate(USER_DUZ, "")
  end

  def test_add_signs_a_note
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_sign_record, NOTE_IEN, "0")
    end

    result = RpmsRpc::ESignature.add(NOTE_IEN, USER_DUZ, SIG_CODE)
    assert result[:success]
  end

  def test_add_dispatches_with_sign_action_marker_by_default
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_sign_record, NOTE_IEN, "0")
    end

    RpmsRpc::ESignature.add(NOTE_IEN, USER_DUZ, SIG_CODE)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "TIU SIGN RECORD" }
    assert_equal [ NOTE_IEN, USER_DUZ, SIG_CODE, "S" ], call[:params]
  end

  def test_add_supports_cosign_and_addend_actions
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_sign_record, NOTE_IEN, "0")
    end

    RpmsRpc::ESignature.add(NOTE_IEN, USER_DUZ, SIG_CODE, action: :cosign)
    RpmsRpc::ESignature.add(NOTE_IEN, USER_DUZ, SIG_CODE, action: :addend)

    calls = RpmsRpc.client.received_calls.select { |c| c[:rpc] == "TIU SIGN RECORD" }
    assert_equal "C", calls[-2][:params][3]
    assert_equal "A", calls[-1][:params][3]
  end

  def test_add_raises_on_unknown_action
    assert_raises(ArgumentError) { RpmsRpc::ESignature.add(NOTE_IEN, USER_DUZ, SIG_CODE, action: :nope) }
  end

  def test_remove_dispatches_with_delete_marker_and_reason
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_sign_record, NOTE_IEN, "0")
    end

    RpmsRpc::ESignature.remove(NOTE_IEN, USER_DUZ, reason: "entered in error")
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "TIU SIGN RECORD" }
    assert_equal "D", call[:params][3], "action code at position 3 across sign/remove"
    assert_equal "entered in error", call[:params][2]
  end

  def test_remove_requires_reason
    refute RpmsRpc::ESignature.remove(NOTE_IEN, USER_DUZ, reason: "")[:success]
    refute RpmsRpc::ESignature.remove(NOTE_IEN, USER_DUZ, reason: nil)[:success]
  end

  def test_blank_args_return_failure
    refute RpmsRpc::ESignature.add(nil, USER_DUZ, SIG_CODE)[:success]
    refute RpmsRpc::ESignature.add(NOTE_IEN, "0", SIG_CODE)[:success]
    refute RpmsRpc::ESignature.add(NOTE_IEN, USER_DUZ, "")[:success]
  end

  def test_which_action_maps_server_code_to_symbol
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_which_signature_action, NOTE_IEN, "S")
    end

    assert_equal :sign, RpmsRpc::ESignature.which_action(NOTE_IEN, USER_DUZ)
  end

  def test_which_action_handles_cosign_and_addend_codes
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_which_signature_action, NOTE_IEN, "C")
    end
    assert_equal :cosign, RpmsRpc::ESignature.which_action(NOTE_IEN, USER_DUZ)

    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_which_signature_action, NOTE_IEN, "A")
    end
    assert_equal :addend, RpmsRpc::ESignature.which_action(NOTE_IEN, USER_DUZ)
  end

  def test_which_action_returns_nil_when_no_action_permitted
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_which_signature_action, NOTE_IEN, "")
    end
    assert_nil RpmsRpc::ESignature.which_action(NOTE_IEN, USER_DUZ)
  end

  def test_which_action_returns_nil_for_invalid_ids
    assert_nil RpmsRpc::ESignature.which_action(nil, USER_DUZ)
    assert_nil RpmsRpc::ESignature.which_action(NOTE_IEN, "0")
  end
end
