# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/authentication"

class AuthenticationTest < Minitest::Test
  def setup
    RpmsRpc::Authentication.clear_cache!
    RpmsRpc.mock! do |m|
      m.seed_scalar(:signon_setup, "", "OK")
      m.seed_user("301",
        credentials: "ACCESS123;VERIFY123",
        name: "PROVIDER,TEST",
        role: :provider,
        security_keys: [ :cprs_gui_chart, :prc_supervisor ])
      m.seed_lines(:av_code, "EXPIRED;VERIFY123", {
        duz: 301,
        error_code: 12,
        verify_needs_change: 1,
        message: "Verify code expired",
        user_class: 3
      })
      m.seed_lines(:cvc_verify, "OLDVERIFY^NEWVERIFY^NEWVERIFY", { result_code: 0 })
    end
  end

  def teardown
    RpmsRpc::Authentication.clear_cache!
    RpmsRpc.reset!
  end

  def test_authenticate_runs_signon_setup_then_av_code_and_user_info
    result = RpmsRpc::Authentication.authenticate(access_code: " access123 ", verify_code: " verify123 ")

    assert_equal true, result[:success]
    assert_equal 301, result[:duz]
    assert_equal 301, result[:provider_ien]
    assert_equal "provider", result[:user_type]
    assert_equal "PROVIDER,TEST", result[:name]

    assert_equal [ "XUS SIGNON SETUP", "XUS AV CODE", "XUS GET USER INFO" ],
      RpmsRpc.client.received_calls.first(3).map { |c| c[:rpc] }
  end

  # XUSRB.VALIDAV ALWAYS runs $$DECRYP^XUSRB1 on its parameter, so a cleartext
  # access;verify pair can never authenticate against a real broker no matter
  # how correct the credentials are (rpms-rpc#200). The pair must cross the
  # wire through the XWB cipher, exactly as Client#authenticate and
  # ESignature already do.
  def test_authenticate_encrypts_the_av_pair_the_way_the_broker_decrypts_it
    RpmsRpc::Authentication.authenticate(access_code: "access123", verify_code: "verify123")

    params = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "XUS AV CODE" }[:params]

    assert_equal 1, params.length,
      "the ciphertext may contain ^, so it must cross the wire as ONE parameter"
    refute_equal "ACCESS123;VERIFY123", params.first,
      "cleartext reaches $$DECRYP^XUSRB1 as garbage — a real broker rejects valid credentials"
    assert_equal "ACCESS123;VERIFY123", RpmsRpc::XwbCipher.decrypt(params.first),
      "the broker must recover the normalized pair from the ciphertext"
  end

  # Verifying the gate, not just the fix: MockClient models $$DECRYP^XUSRB1,
  # so a caller that reverts to a cleartext send fails here the way it would
  # in production rather than passing on a mock that expected the bug.
  #
  # The reply shape is VALIDAV^XUSRB's own, read from the M source:
  #   RET(0)=DUZ  RET(1)=XUM  RET(2)=VCCH  RET(3)=message  RET(4)=0  RET(5)=msg count
  # A bad A/V code leaves DUZ 0 and XUM 0 (XUM is 1 only for inhibited logons
  # and the three-strike lock); UVALID^XUS returns 4 for DUZ'>0 and
  # TXT^XUS3(4) is "Invalid A/V code.".
  def test_mock_broker_rejects_a_cleartext_av_parameter
    parsed = RpmsRpc::DataMapper.av_code.fetch_lines("ACCESS123;VERIFY123")

    assert_equal 0, parsed[:duz]
    assert_equal 0, parsed[:error_code]
    assert_equal "Invalid A/V code.", parsed[:message]
  end

  # VALIDAV ALWAYS builds RET(0..5) — there is no path on which it answers
  # with nothing. A mock that returned "" for unknown credentials was
  # inventing a wire behaviour the broker does not have, and the old
  # "Invalid response" assertion codified that fiction.
  def test_unknown_but_encrypted_credentials_get_validavs_own_reply_shape
    parsed = RpmsRpc::DataMapper.av_code.fetch_lines(RpmsRpc::XwbCipher.encrypt("NOSUCH;USER1"))

    refute_nil parsed, "VALIDAV always returns structured lines, never an empty reply"
    assert_equal 0, parsed[:duz]
    assert_equal 0, parsed[:error_code]
    assert_equal "Invalid A/V code.", parsed[:message]
  end

  def test_authenticate_rejects_blank_access_or_verify_code
    assert_equal({ success: false, error: "Access code is required" },
      RpmsRpc::Authentication.authenticate(access_code: "", verify_code: "VERIFY123"))
    assert_equal({ success: false, error: "Verify code is required" },
      RpmsRpc::Authentication.authenticate(access_code: "ACCESS123", verify_code: " "))
  end

  def test_authenticate_returns_failure_for_unknown_credentials
    result = RpmsRpc::Authentication.authenticate(access_code: "BAD", verify_code: "CODES")

    assert_equal false, result[:success]
    # VALIDAV's own message for a bad pair (TXT^XUS3(4)), not a synthesised one.
    assert_equal "Invalid A/V code.", result[:error]
  end

  def test_authenticate_maps_verify_code_expired_response
    result = RpmsRpc::Authentication.authenticate(access_code: "EXPIRED", verify_code: "VERIFY123")

    assert_equal false, result[:success]
    assert_equal 301, result[:duz]
    assert_equal "Verify code expired - must be changed", result[:error]
    assert_equal 12, result[:error_code]
    assert_equal true, result[:verify_needs_change]
  end

  def test_user_info_returns_user_details
    info = RpmsRpc::Authentication.user_info(301)

    assert_equal 301, info[:duz]
    assert_equal "PROVIDER,TEST", info[:name]
    assert_equal "PROVIDER,TEST", info[:display_name]
    # :user_class_ien is a pointer into USER CLASS file #8932.1; assert
    # positivity rather than a specific value (the mock seeds a placeholder
    # IEN, live values are site-specific).
    assert info[:user_class_ien].is_a?(Integer) && info[:user_class_ien] > 0
  end

  def test_user_info_rejects_blank_zero_negative_and_non_numeric_duz
    assert_nil RpmsRpc::Authentication.user_info(nil)
    assert_nil RpmsRpc::Authentication.user_info("")
    assert_nil RpmsRpc::Authentication.user_info(0)
    assert_nil RpmsRpc::Authentication.user_info(-1)
    assert_nil RpmsRpc::Authentication.user_info("abc")
  end

  def test_user_info_returns_nil_for_unknown_duz
    assert_nil RpmsRpc::Authentication.user_info(999_999)
  end

  def test_user_security_keys_returns_seeded_keys
    keys = RpmsRpc::Authentication.user_security_keys(301)

    assert_equal [ "OR CPRS GUI CHART", "PRCFA SUPERVISOR" ], keys
  end

  def test_user_security_keys_rejects_invalid_duz
    assert_equal [], RpmsRpc::Authentication.user_security_keys(nil)
    assert_equal [], RpmsRpc::Authentication.user_security_keys(0)
    assert_equal [], RpmsRpc::Authentication.user_security_keys(-1)
  end

  def test_user_security_keys_returns_empty_when_capability_unsupported
    RpmsRpc.client.seed_capability(:user_security_keys_list, supported: false)
    assert_equal [], RpmsRpc::Authentication.user_security_keys(301)
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWU USERKEYS" }
  end

  def test_has_security_key_uses_duz_and_key_name
    RpmsRpc.mock! do |m|
      m.seed_scalar(:user_has_key, "301", true)
    end

    assert_equal true, RpmsRpc::Authentication.has_security_key?(301, "OR CPRS GUI CHART")
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWU HASKEY" }
    assert_equal [ "301", "OR CPRS GUI CHART" ], call[:params]
  end

  def test_has_security_key_rejects_invalid_arguments
    assert_equal false, RpmsRpc::Authentication.has_security_key?(nil, "OR CPRS GUI CHART")
    assert_equal false, RpmsRpc::Authentication.has_security_key?(0, "OR CPRS GUI CHART")
    assert_equal false, RpmsRpc::Authentication.has_security_key?(301, "")
  end

  def test_change_verify_code_sends_caret_delimited_uppercase_payload
    result = RpmsRpc::Authentication.change_verify_code(
      old_verify_code: " oldverify ",
      new_verify_code: " newverify ",
      confirm_verify_code: " newverify "
    )

    assert_equal({ success: true }, result)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "XUS CVC" }

    assert_equal 1, call[:params].length, "the triple crosses the wire as ONE parameter"

    # CVC^XUSRB (XUSRB.m:70-71) SPLITS ON ^ FIRST, THEN DECRYPTS EACH PIECE:
    #   S XU2=$P(XU1,U,2),XU3=$P(XU1,U,3),XU1=$P(XU1,U)
    #   S XU1=$$DECRYP^XUSRB1(XU1),XU2=$$DECRYP^XUSRB1(XU2),XU3=$$DECRYP^XUSRB1(XU3)
    # so each component must be encrypted separately and joined with ^.
    # Encrypting the whole triple as one blob is decrypted as garbage — the
    # delimiter falls inside the ciphertext. (The cipher table deliberately
    # omits ^, which is exactly what makes per-component framing safe; verify
    # codes exclude it too, per AVHLPTXT^XUS2.)
    pieces = call[:params].first.split("^", -1)
    assert_equal 3, pieces.length, "CVC splits its parameter into three caret pieces before decrypting"

    assert_equal %w[OLDVERIFY NEWVERIFY NEWVERIFY],
      pieces.map { |piece| RpmsRpc::XwbCipher.decrypt(piece) }
    refute_includes pieces, "OLDVERIFY", "the components must not cross the wire in cleartext"
  end

  # Gate for the CVC path, derived from CVC^XUSRB rather than from the AV path.
  def test_mock_broker_rejects_a_cleartext_cvc_parameter
    parsed = RpmsRpc::DataMapper.cvc_verify.fetch_lines("OLDVERIFY^NEWVERIFY^NEWVERIFY")

    assert_equal 1, parsed[:result_code],
      "BRCVC^XUS2 answers 1^msg when the current code does not match"
  end

  # A whole-triple encryption is the defect this PR originally shipped: the
  # server splits on ^ before decrypting, so the pieces are garbage.
  def test_mock_broker_rejects_a_whole_triple_encryption
    parsed = RpmsRpc::DataMapper.cvc_verify.fetch_lines(
      RpmsRpc::XwbCipher.encrypt("OLDVERIFY^NEWVERIFY^NEWVERIFY")
    )

    assert_equal 1, parsed[:result_code]
  end

  def test_change_verify_code_rejects_blank_fields
    result = RpmsRpc::Authentication.change_verify_code(
      old_verify_code: "OLDVERIFY",
      new_verify_code: "",
      confirm_verify_code: "NEWVERIFY"
    )

    assert_equal false, result[:success]
    assert_equal "New verify code is required", result[:error]
  end

  def test_change_verify_code_treats_unseeded_response_as_failure
    # Unseeded payload → MockClient returns "" → fetch_lines returns nil.
    # Without an explicit result-code check, the previous code would treat
    # this as success because `nil.to_i == 0`.
    result = RpmsRpc::Authentication.change_verify_code(
      old_verify_code: "WRONGOLD",
      new_verify_code: "NEWVERIFY",
      confirm_verify_code: "NEWVERIFY"
    )

    assert_equal false, result[:success]
    assert_equal "Verify code change failed", result[:error]
  end
end
