# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/authentication"
require_relative "../captured_replies"

# Authentication.held_keys against the ORWU NPHASKEY replies a fresh rpms-ydb
# container sent for PROFILE,MD (DUZ 206), who holds ORES and not XUPROG
# (test/fixtures/captured_replies/authentication.yml), replayed through
# CiaClient (rpms-rpc#521). The wire framing, sequence echo and reply-shape
# cases are in authentication_held_keys_test.rb.
class RpmsRpc::AuthenticationHeldKeysRepliesTest < Minitest::Test
  SLUG = "authentication"
  NPHASKEY = "ORWU NPHASKEY"
  HELD_CONTEXT = RpmsRpc::Authentication::HELD_KEYS_CONTEXT

  def teardown
    RpmsRpc.reset!
  end

  def capture(name) = CapturedReplies.raw(SLUG, name)

  def replay(replies, client_class: CapturedReplies::ReplayCiaClient)
    client = client_class.new(NPHASKEY => replies).signed_on_as("206")
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def nphaskey_calls(client) = client.calls.select { |c| c[:rpc] == NPHASKEY }

  def test_held_keys_reports_the_held_key_and_omits_the_unheld_in_order
    client = replay([ capture("nphaskey_held"), capture("nphaskey_unheld") ])

    assert_equal [ "ORES" ], RpmsRpc::Authentication.held_keys(%w[ORES XUPROG])
    assert_equal [ [ "206", "ORES" ], [ "206", "XUPROG" ] ], nphaskey_calls(client).map { |c| c[:params] }
  end

  def test_held_keys_binds_its_context_for_the_batch_and_restores_the_callers
    client = replay([ capture("nphaskey_held") ])
    client.create_context("AGGRPC")

    RpmsRpc::Authentication.held_keys(%w[ORES])

    binds = client.calls.select { |c| c[:rpc] == :create_context }.map { |c| c[:params].first }
    assert_equal [ "AGGRPC", HELD_CONTEXT, "AGGRPC" ], binds
    assert_equal "AGGRPC", client.current_context
  end

  # A refused call (the build's own "Access denied" reply) is "could not ask": nil.
  def test_held_keys_returns_nil_when_a_call_is_refused
    replay([ capture("nphaskey_held"), capture("nphaskey_refused") ])

    assert_nil RpmsRpc::Authentication.held_keys(%w[ORES XUPROG])
  end

  def test_held_keys_agrees_with_has_security_key
    replay([ capture("nphaskey_held"), capture("nphaskey_unheld"), capture("nphaskey_held"), capture("nphaskey_unheld") ])

    held = RpmsRpc::Authentication.held_keys(%w[ORES XUPROG])

    assert_equal RpmsRpc::Authentication.has_security_key?("206", "ORES"), held.include?("ORES")
    assert_equal RpmsRpc::Authentication.has_security_key?("206", "XUPROG"), held.include?("XUPROG")
  end

  # held_keys reads the DUZ under the wire lock, inside the bound context
  # (rpms-rpc#521 r2): a sign-on that lands before the scope is entered names
  # the user every ORWU NPHASKEY asks about.
  class RebindBeforeScopeClient < CapturedReplies::ReplayCiaClient
    def with_context(option_name, &block)
      signed_on_as("207")
      super
    end
  end

  def test_held_keys_uses_the_duz_read_inside_the_scope
    client = replay([ capture("nphaskey_unheld") ], client_class: RebindBeforeScopeClient)

    RpmsRpc::Authentication.held_keys(%w[ORES])

    assert_equal [ [ "207", "ORES" ] ], nphaskey_calls(client).map { |c| c[:params] }
  end

  class CallRpcOnlyDouble
    attr_reader :calls

    def initialize = @calls = []

    def call_rpc(*args)
      @calls << args
      raise "a client with no #duz must not be asked"
    end

    def with_context(_option_name, &block) = block.call
  end

  def test_held_keys_returns_nil_when_the_client_has_no_duz_method
    double = CallRpcOnlyDouble.new
    RpmsRpc.configure { |cfg| cfg.client = double }

    assert_nil RpmsRpc::Authentication.held_keys([ "ORES" ])
    assert_empty double.calls
  end
end
