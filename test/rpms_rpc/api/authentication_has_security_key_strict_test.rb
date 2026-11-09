# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/authentication"
require_relative "../captured_replies"

# has_security_key? reads ORWU NPHASKEY like held_key_flag: not altered, exactly
# one normalised data line, strictly "0" or "1" (rpms-rpc#556). The replies are
# the build's (test/fixtures/captured_replies/authentication.yml): PROFILE,MD
# (DUZ 206) holds ORES and not XUPROG, and AGGRPC does not carry the RPC.
#
# The build answers "1", "0" or a refusal. The other shapes the strict read
# refuses ("2", "yes", " 1", two lines, an altered line) were tested against
# replies written by hand, which ADR 0009 retires; the CIA framing cases are in
# authentication_held_keys_test.rb.
class RpmsRpc::AuthenticationHasSecurityKeyStrictTest < Minitest::Test
  SLUG = "authentication"
  NPHASKEY = "ORWU NPHASKEY"
  DUZ = "206"

  def teardown
    RpmsRpc.reset!
  end

  def capture(name) = CapturedReplies.raw(SLUG, name)

  def replay(*names)
    client = CapturedReplies::ReplayCiaClient.new(NPHASKEY => names.map { |name| capture(name) }).signed_on_as(DUZ)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def test_has_security_key_is_true_for_a_held_key
    replay("nphaskey_held")

    assert_equal true, RpmsRpc::Authentication.has_security_key?(DUZ, "ORES")
  end

  def test_has_security_key_is_false_for_an_unheld_key
    replay("nphaskey_unheld")

    assert_equal false, RpmsRpc::Authentication.has_security_key?(DUZ, "XUPROG")
  end

  # A refused call is not "does not hold": it raises.
  def test_has_security_key_propagates_the_builds_refusal_instead_of_returning_false
    replay("nphaskey_refused")

    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Authentication.has_security_key?(DUZ, "ORES") }
  end

  def test_has_security_key_sends_exactly_one_orwu_nphaskey_with_duz_and_key_params
    client = replay("nphaskey_held")

    RpmsRpc::Authentication.has_security_key?(DUZ, "ORES")

    assert_equal [ { rpc: NPHASKEY, params: [ DUZ, "ORES" ] } ], client.calls
  end

  def test_has_security_key_does_not_bind_or_change_the_callers_context
    client = replay("nphaskey_held")
    client.create_context("AGGRPC")

    RpmsRpc::Authentication.has_security_key?(DUZ, "ORES")

    assert_equal "AGGRPC", client.current_context
    assert_equal [ :create_context, NPHASKEY ], client.rpcs_called
  end

  # --- guards: nothing reaches the wire --------------------------------------

  def test_has_security_key_returns_false_for_an_invalid_duz_or_key_and_sends_nothing
    client = replay

    [ nil, 0, -5, "900001abc" ].each do |duz|
      refute RpmsRpc::Authentication.has_security_key?(duz, "ORES"), "duz #{duz.inspect}"
    end
    refute RpmsRpc::Authentication.has_security_key?(DUZ, "  ")
    assert_empty client.calls
  end

  # --- agreement with held_keys on every reply the build sends ---------------

  def test_has_security_key_agrees_with_held_keys_on_each_captured_reply
    { "nphaskey_held" => "ORES", "nphaskey_unheld" => "XUPROG" }.each do |name, key|
      replay(name, name)
      held = RpmsRpc::Authentication.held_keys([ key ])
      has = RpmsRpc::Authentication.has_security_key?(DUZ, key)

      assert_equal held.include?(key), has, "reply #{name}: held_keys=#{held.inspect}"
    end

    replay("nphaskey_refused", "nphaskey_refused")
    assert_nil RpmsRpc::Authentication.held_keys([ "ORES" ]), "a refusal is 'could not ask' for held_keys"
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Authentication.has_security_key?(DUZ, "ORES") }
  end
end
