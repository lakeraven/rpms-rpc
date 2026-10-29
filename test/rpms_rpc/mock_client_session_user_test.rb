# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/authentication"

# MockClient#seed_user (rpms-rpc#469): a successful XUS AV CODE binds the
# session-user replies (XUS GET USER INFO, ORWU USERINFO) to the DUZ it names,
# from that user's own seed_user arguments. Synthetic users and credentials
# only. The mock is not wire evidence: a real broker answers these RPCs for the
# user the sign-on bound, and this makes the mock answer the same way.
class MockClientSessionUserTest < Minitest::Test
  def setup
    RpmsRpc::Authentication.clear_cache!
  end

  def teardown
    RpmsRpc::Authentication.clear_cache!
    RpmsRpc.reset!
  end

  def seed_provider_then_clerk(mock)
    mock.seed_scalar(:signon_setup, "", "OK")
    mock.seed_user("301", credentials: "PROVIDER1;PROVVERIFY1", name: "PROVIDER,TEST", role: :provider)
    mock.seed_user("302", credentials: "CLERK1;CLERKVERIFY1", name: "CLERK,TEST", role: :clerk)
  end

  def sign_on(access, verify)
    RpmsRpc::Authentication.authenticate(access_code: access, verify_code: verify)
  end

  def test_signing_on_as_the_first_of_two_seeded_users_answers_for_that_user
    RpmsRpc.mock! { |m| seed_provider_then_clerk(m) }

    result = sign_on("PROVIDER1", "PROVVERIFY1")

    assert result[:success]
    assert_equal 301, result[:duz]
    assert_equal "PROVIDER,TEST", result[:name]
    assert_equal "provider", RpmsRpc::Authentication.user_type(301)
    assert_equal 301, RpmsRpc::Authentication.user_info(301)[:duz]
  end

  def test_signing_on_as_the_second_user_afterwards_switches_both_replies
    RpmsRpc.mock! { |m| seed_provider_then_clerk(m) }

    sign_on("PROVIDER1", "PROVVERIFY1")
    assert_equal "provider", RpmsRpc::Authentication.user_type(301)

    result = sign_on("CLERK1", "CLERKVERIFY1")

    assert result[:success]
    assert_equal 302, result[:duz]
    assert_equal "CLERK,TEST", result[:name]
    assert_equal "clerk", RpmsRpc::Authentication.user_type(302)
    assert_equal 302, RpmsRpc::Authentication.user_info(302)[:duz]
  end

  def test_seeding_another_user_after_a_sign_on_leaves_the_bound_replies_alone
    mock = nil
    RpmsRpc.mock! do |m|
      mock = m
      seed_provider_then_clerk(m)
    end

    sign_on("PROVIDER1", "PROVVERIFY1")
    mock.seed_user("303", credentials: "NURSE1;NURSEVERIFY1", name: "NURSE,TEST", role: :nurse)

    assert_equal 301, RpmsRpc::Authentication.user_info(301)[:duz]
    assert_equal "provider", RpmsRpc::Authentication.user_type(301)
  end

  def test_reseeding_the_bound_user_refreshes_its_replies
    mock = nil
    RpmsRpc.mock! do |m|
      mock = m
      seed_provider_then_clerk(m)
    end

    sign_on("PROVIDER1", "PROVVERIFY1")
    mock.seed_user("301", credentials: "PROVIDER1;PROVVERIFY1", name: "PROVIDER,RENAMED", role: :provider)

    assert_equal "PROVIDER,RENAMED", RpmsRpc::Authentication.user_info(301)[:name]
  end

  def test_a_failed_sign_on_leaves_the_bound_replies_alone
    RpmsRpc.mock! do |m|
      seed_provider_then_clerk(m)
      # Credentials that resolve but fail, naming the clerk's DUZ.
      m.seed_lines(:av_code, "CLERK1;WRONGVERIFY", {
        duz: 302, error_code: 12, verify_needs_change: 0,
        message: "Verify code expired", post_signon_message_count: 0
      })
    end

    sign_on("PROVIDER1", "PROVVERIFY1")
    failed = sign_on("CLERK1", "WRONGVERIFY")

    refute failed[:success]
    assert_equal "provider", RpmsRpc::Authentication.user_type(301),
      "a refused sign-on must not rebind the session user"
    assert_nil RpmsRpc::Authentication.user_info(302)
  end

  def test_a_user_seeded_without_seed_user_keeps_their_replies_after_sign_on
    RpmsRpc.mock! do |m|
      seed_provider_then_clerk(m)
      # A user the host seeded by hand, after the seed_user ones.
      m.seed_lines(:av_code, "PLAIN1;PLAINVERIFY1", {
        duz: 500, error_code: 0, verify_needs_change: 0,
        message: "Welcome PLAIN,USER", post_signon_message_count: 0
      })
      m.seed_lines(:user_info, "", { duz: 500, name: "PLAIN,USER", display_name: "PLAIN,USER", current_site: "", dtime: 300 })
      m.seed(:practitioner_info, "", { duz: 500, name: "PLAIN,USER", user_class: 3 })
    end

    sign_on("PLAIN1", "PLAINVERIFY1")

    assert_equal 500, RpmsRpc::Authentication.user_info(500)[:duz]
    assert_equal "provider", RpmsRpc::Authentication.user_type(500)
  end

  # Fail closed: a sign-on that names a DUZ nobody seeded through seed_user
  # keeps today's behaviour (the last seed_user's replies), and never borrows
  # another user's record to answer for it.
  def test_a_sign_on_naming_an_unseeded_duz_does_not_borrow_another_users_reply
    RpmsRpc.mock! do |m|
      seed_provider_then_clerk(m)
      m.seed_lines(:av_code, "GHOST1;GHOSTVERIFY1", {
        duz: 777, error_code: 0, verify_needs_change: 0,
        message: "Welcome GHOST,USER", post_signon_message_count: 0
      })
    end

    sign_on("PROVIDER1", "PROVVERIFY1")
    result = sign_on("GHOST1", "GHOSTVERIFY1")

    assert result[:success]
    assert_equal 777, result[:duz]
    assert_nil RpmsRpc::Authentication.user_info(777),
      "no user was seeded for DUZ 777, so no session-user reply may name it"
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Authentication.user_type(777) }
  end
end
