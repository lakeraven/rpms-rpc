# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/xwb_cipher"
require "rpms_rpc/api/authentication"
require_relative "../captured_replies"

# Authentication against the replies a fresh rpms-ydb container sent
# (test/fixtures/captured_replies/authentication.yml). Sign-on runs over BMX,
# replayed through BmxClient's own reply reader: the CIA broker refuses XUS
# SIGNON SETUP and XUS AV CODE once CIANBRPC AUTH has signed a session on. The
# ORWU USERINFO reads run over CIA as each persona.
#
# Not captured, so not tested here: a verify code that has expired (error 12),
# and the reply shapes no build sends (a blank or non-numeric USRCLS, a blank
# DTIME). The round trip over XWB is test/live/xwb/authenticate_live_test.rb.
class AuthenticationTest < Minitest::Test
  SLUG = "authentication"

  # Answers nil for every call, for the empty-reply path no capture holds.
  class NilReplyClient
    def call_rpc(*) = nil
    def call_rpc_lines(*) = nil
  end

  def setup
    RpmsRpc::Authentication.clear_cache!
  end

  def teardown
    RpmsRpc::Authentication.clear_cache!
    RpmsRpc.reset!
  end

  # A BMX session that answers the named sign-on flow's frames.
  def replay_flow(name)
    client = CapturedReplies::ReplayBmxClient.new(CapturedReplies.flow_script(SLUG, name))
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  # A CIA session that answers the named ORWU USERINFO capture.
  def replay_userinfo(name)
    client = CapturedReplies::ReplayCiaClient.new("ORWU USERINFO" => [ CapturedReplies.raw(SLUG, name) ])
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  # A BMX session signed on as PROFILE,MD that answers XUS GET USER INFO.
  def replay_user_info
    frame = CapturedReplies.flow(SLUG, "signon").find { |c| c["rpc"] == "XUS GET USER INFO" }.fetch("raw_return").b
    client = CapturedReplies::ReplayBmxClient.new("XUS GET USER INFO" => [ frame ])
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sign_on_as_md = RpmsRpc::Authentication.authenticate(access_code: " pmd123 ", verify_code: " pmd123!! ")

  # -- sign-on ---------------------------------------------------------------

  def test_authenticate_runs_signon_setup_then_av_code_and_user_info
    client = replay_flow("signon")

    result = sign_on_as_md

    assert_equal({ success: true, duz: 206, provider_ien: 206, message: "", verify_needs_change: false,
                   post_signon_message_count: 0, name: "PROFILE,MD" }, result)
    refute result.key?(:user_type), "the sign-on result carries no user class (Authentication.user_type is the read)"
    assert_equal [ "XUS SIGNON SETUP", "XUS AV CODE", "XUS GET USER INFO" ], client.rpcs_called
  end

  # A host that signs on through this API binds its context next (ORWU USERINFO,
  # for #user_type, needs one), so the client must come out of it signed on.
  def test_a_sign_on_here_lets_the_client_bind_a_context_and_read_the_user_class
    client = replay_flow("signon")
    refute client.authenticated?

    assert sign_on_as_md[:success]

    assert client.authenticated?
    assert_equal "206", client.duz
    assert client.create_context("CIAV VUECENTRIC")
    assert_equal "provider", RpmsRpc::Authentication.user_type(206)
    assert_equal CapturedReplies.flow_calls(SLUG, "signon").map(&:first), client.rpcs_called
  end

  # A failed second sign-on leaves the client signed on as nobody, not as the
  # first user: the attempt re-bound the broker session.
  def test_a_failed_second_sign_on_clears_the_first_identity
    client = replay_flow("second_signon")
    assert RpmsRpc::Authentication.authenticate(access_code: "PSCH123", verify_code: "PSCH123!!")[:success]
    assert_equal "208", client.duz

    refute RpmsRpc::Authentication.authenticate(access_code: "PSCH123", verify_code: "WRONG123")[:success]

    refute client.authenticated?
    assert_nil client.duz
    assert_raises(RpmsRpc::Client::AuthenticationError) { client.create_context("CIAV VUECENTRIC") }
  end

  # XUSRB.VALIDAV ALWAYS runs $$DECRYP^XUSRB1 on its parameter, so a cleartext
  # access;verify pair can never authenticate against a real broker
  # (rpms-rpc#200). The pair crosses the wire through the XWB cipher, as one
  # parameter, normalized (stripped, upper case).
  def test_authenticate_encrypts_the_av_pair_the_way_the_broker_decrypts_it
    client = replay_flow("signon")

    sign_on_as_md

    params = client.calls.find { |c| c[:rpc] == "XUS AV CODE" }[:params]
    assert_equal 1, params.length, "the ciphertext may contain ^, so it must cross the wire as ONE parameter"
    refute_equal "PMD123;PMD123!!", params.first, "cleartext reaches $$DECRYP^XUSRB1 as garbage"
    assert_equal "PMD123;PMD123!!", RpmsRpc::XwbCipher.decrypt(params.first),
                 "the broker must recover the normalized pair from the ciphertext"
  end

  # VALIDAV's own reply for a pair no user holds: DUZ 0, its own message.
  def test_authenticate_returns_failure_for_unknown_credentials
    replay_flow("signon_unknown")

    result = RpmsRpc::Authentication.authenticate(access_code: "NOSUCH", verify_code: "USER1")

    assert_equal({ success: false, duz: nil, error: "Not a valid ACCESS CODE/VERIFY CODE pair.", error_code: 0,
                   verify_needs_change: false }, result)
  end

  def test_authenticate_rejects_blank_access_or_verify_code_without_a_call
    client = replay_flow("signon")

    assert_equal({ success: false, error: "Access code is required" },
                 RpmsRpc::Authentication.authenticate(access_code: "", verify_code: "VERIFY123"))
    assert_equal({ success: false, error: "Verify code is required" },
                 RpmsRpc::Authentication.authenticate(access_code: "ACCESS123", verify_code: " "))
    assert_empty client.calls
  end

  # -- user class and idle limit (ORWU USERINFO) ------------------------------

  # The user's class is ORWU USERINFO's USRCLS (piece 3), in the vocabulary
  # hosts read: PROFILE,MD 3, PROFILE,RN 2, PROFILE,SCHED 0 on the build.
  def test_user_type_reads_orwu_usrcls
    client = replay_userinfo("userinfo_md")
    assert_equal "provider", RpmsRpc::Authentication.user_type(206)
    assert_equal [ "ORWU USERINFO" ], client.rpcs_called

    replay_userinfo("userinfo_rn")
    assert_equal "nurse", RpmsRpc::Authentication.user_type(205)

    replay_userinfo("userinfo_sched")
    assert_equal "user", RpmsRpc::Authentication.user_type(208)
  end

  def test_user_type_raises_when_the_answer_is_for_another_user
    replay_userinfo("userinfo_md")

    e = assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Authentication.user_type(301) }
    assert_includes e.message, "another user"
  end

  # ORWU USERINFO piece 8 is the user's DTIME: their own TIMED READ, else the
  # site default (PROFILE,SCHED 600, PROFILE,MD 9999 on the build).
  def test_timed_read_is_the_users_idle_limit_in_seconds
    replay_userinfo("userinfo_sched")
    assert_equal 600, RpmsRpc::Authentication.timed_read(208)

    replay_userinfo("userinfo_md")
    assert_equal 9999, RpmsRpc::Authentication.timed_read(206)
  end

  def test_timed_read_raises_when_the_answer_is_for_another_user
    replay_userinfo("userinfo_md")

    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Authentication.timed_read(208) }
  end

  # USRCLS is computed from the user's order keys (ORWU.m:19). Anything else is
  # not a class RPMS reports, so it maps to nil, never to a default (#236).
  def test_user_type_for_maps_orwu_usrcls
    assert_equal "provider", RpmsRpc::Authentication.user_type_for(3)
    assert_equal "nurse", RpmsRpc::Authentication.user_type_for(2)
    assert_equal "clerk", RpmsRpc::Authentication.user_type_for(1)
    assert_equal "user", RpmsRpc::Authentication.user_type_for(0)
    assert_equal "provider", RpmsRpc::Authentication.user_type_for("3")
    [ nil, "", 4, 5, -1, "x", "3x" ].each do |usrcls|
      assert_nil RpmsRpc::Authentication.user_type_for(usrcls), "USRCLS #{usrcls.inspect} is not one ORWU.m:19 returns"
    end
  end

  # -- user info (XUS GET USER INFO) -----------------------------------------

  def test_user_info_returns_user_details
    replay_user_info

    info = RpmsRpc::Authentication.user_info(206)

    assert_equal 206, info[:duz]
    assert_equal "PROFILE,MD", info[:name]
    assert_equal "Md Profile", info[:display_name]
    # Line 7 is the user's DTIME (USERINFO^XUSRB2, XUSRB2.m:35), not a user-class pointer.
    assert_equal 9999, info[:dtime]
    refute info.key?(:user_class_ien)
  end

  # XUS GET USER INFO answers for the session's user; a DUZ that is not the
  # session's reads nil.
  def test_user_info_returns_nil_when_the_session_is_another_user
    replay_user_info

    assert_nil RpmsRpc::Authentication.user_info(999_999)
  end

  def test_user_info_rejects_blank_zero_negative_and_non_numeric_duz_without_a_call
    client = replay_flow("signon")

    [ nil, "", 0, -1, "abc" ].each { |duz| assert_nil RpmsRpc::Authentication.user_info(duz) }
    assert_empty client.calls
  end

  # has_security_key? against the build's replies: authentication_has_security_key_strict_test.rb.
  def test_has_security_key_rejects_invalid_arguments_without_a_call
    client = replay_flow("signon")

    assert_equal false, RpmsRpc::Authentication.has_security_key?(nil, "SD SUPERVISOR")
    assert_equal false, RpmsRpc::Authentication.has_security_key?(0, "SD SUPERVISOR")
    assert_equal false, RpmsRpc::Authentication.has_security_key?(206, "")
    assert_empty client.calls
  end

  # -- change verify code (XUS CVC) -------------------------------------------

  def test_change_verify_code_sends_each_component_encrypted_and_reads_success
    client = replay_flow("cvc")
    RpmsRpc::Authentication.authenticate(access_code: "PRN123", verify_code: "PRN123!!")

    result = RpmsRpc::Authentication.change_verify_code(old_verify_code: " prn123!! ", new_verify_code: " qzx456!!wv ",
                                                        confirm_verify_code: " qzx456!!wv ")

    assert_equal({ success: true }, result)
    call = client.calls.find { |c| c[:rpc] == "XUS CVC" }
    assert_equal 1, call[:params].length, "the triple crosses the wire as ONE parameter"
    # CVC^XUSRB (XUSRB.m:70-71) SPLITS ON ^ FIRST, THEN DECRYPTS EACH PIECE, so
    # each component is encrypted separately and joined with ^.
    pieces = call[:params].first.split("^", -1)
    assert_equal 3, pieces.length, "CVC splits its parameter into three caret pieces before decrypting"
    assert_equal %w[PRN123!! QZX456!!WV QZX456!!WV], pieces.map { |piece| RpmsRpc::XwbCipher.decrypt(piece) }
    refute_includes pieces, "PRN123!!", "the components must not cross the wire in cleartext"
  end

  # BRCVC^XUS2 answers 1 and its message when the current code does not match.
  def test_change_verify_code_with_a_wrong_current_code_fails
    replay_flow("cvc_wrong_old")
    RpmsRpc::Authentication.authenticate(access_code: "PRN123", verify_code: "PRN123!!")

    result = RpmsRpc::Authentication.change_verify_code(old_verify_code: "WRONGOLD1!", new_verify_code: "QZX456!!WV",
                                                        confirm_verify_code: "QZX456!!WV")

    assert_equal({ success: false, error: "Verify code change failed" }, result)
  end

  def test_change_verify_code_rejects_blank_fields_without_a_call
    client = replay_flow("cvc")

    result = RpmsRpc::Authentication.change_verify_code(old_verify_code: "OLDVERIFY", new_verify_code: "",
                                                        confirm_verify_code: "NEWVERIFY")

    assert_equal({ success: false, error: "New verify code is required" }, result)
    assert_empty client.calls
  end

  # A nil reply is not a result code: `nil.to_i == 0` must not read as success.
  def test_change_verify_code_treats_a_nil_reply_as_failure
    RpmsRpc.configure { |cfg| cfg.client = NilReplyClient.new }

    result = RpmsRpc::Authentication.change_verify_code(old_verify_code: "WRONGOLD", new_verify_code: "NEWVERIFY",
                                                        confirm_verify_code: "NEWVERIFY")

    assert_equal({ success: false, error: "Verify code change failed" }, result)
  end
end
