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
    assert_equal [ "ACCESS123;VERIFY123" ],
      RpmsRpc.client.received_calls.find { |c| c[:rpc] == "XUS AV CODE" }[:params]
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
    assert_equal "Invalid response", result[:error]
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
    assert_nil info[:access_code]
    assert_equal true, info[:verify_code_exists]
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
    assert_equal [ "OLDVERIFY^NEWVERIFY^NEWVERIFY" ], call[:params]
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
end
