# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/mappings"
require "rpms_rpc/api/authentication"

# MockClient must mirror Client sign-on identity (#duz, set_authenticated,
# clear_authenticated) and return NPHASKEY answers held_keys can read the same
# way has_security_key? does (rpms-rpc#521).
class RpmsRpc::AuthenticationHeldKeysMockClientTest < Minitest::Test
  SYNTHETIC_DUZ = "900001"
  NPHASKEY_RPC = RpmsRpc::DataMapper[:person_has_key].rpc_name
  HELD_CONTEXT = RpmsRpc::Authentication::HELD_KEYS_CONTEXT

  def teardown
    RpmsRpc.reset!
  end

  def nphaskey_calls(mock)
    mock.received_calls.select { |c| c[:rpc] == NPHASKEY_RPC }
  end

  def test_fresh_mock_client_has_nil_duz_and_held_keys_sends_no_nphaskey
    mock = RpmsRpc.mock!

    assert_nil mock.duz
    assert_nil RpmsRpc::Authentication.held_keys([ "SYNKEYA" ])
    assert_empty nphaskey_calls(mock)
  end

  def test_set_authenticated_records_duz_on_mock_client
    mock = RpmsRpc.mock!

    mock.set_authenticated(SYNTHETIC_DUZ)

    assert_equal SYNTHETIC_DUZ, mock.duz
  end

  def test_clear_authenticated_clears_duz_on_mock_client
    mock = RpmsRpc.mock!
    mock.set_authenticated(SYNTHETIC_DUZ)

    mock.clear_authenticated

    assert_nil mock.duz
  end

  def test_held_keys_reports_seeded_true_and_false_keys_in_order
    RpmsRpc.mock! do |m|
      m.set_authenticated(SYNTHETIC_DUZ)
      m.seed(:person_has_key, [ SYNTHETIC_DUZ, "SYNKEYA" ], true)
      m.seed(:person_has_key, [ SYNTHETIC_DUZ, "SYNKEYB" ], false)
    end

    assert_equal [ "SYNKEYA" ], RpmsRpc::Authentication.held_keys(%w[SYNKEYA SYNKEYB])
    calls = nphaskey_calls(RpmsRpc.client)
    assert_equal 2, calls.size
    assert calls.all? { |c| c[:context] == HELD_CONTEXT }
    assert_equal [ SYNTHETIC_DUZ, "SYNKEYA" ], calls[0][:params]
    assert_equal [ SYNTHETIC_DUZ, "SYNKEYB" ], calls[1][:params]
  end

  def test_held_keys_returns_nil_when_a_key_is_not_seeded
    RpmsRpc.mock! do |m|
      m.set_authenticated(SYNTHETIC_DUZ)
    end

    assert_nil RpmsRpc::Authentication.held_keys([ "SYNKEYA" ])
    assert_equal 1, nphaskey_calls(RpmsRpc.client).size
  end

  def test_held_keys_agrees_with_has_security_key_for_seeded_keys
    keys = {
      "SYNKEYA" => true,
      "SYNKEYB" => false,
      "SYNKEYC" => true
    }
    RpmsRpc.mock! do |m|
      m.set_authenticated(SYNTHETIC_DUZ)
      keys.each do |name, held|
        m.seed(:person_has_key, [ SYNTHETIC_DUZ, name ], held)
      end
    end

    asked = keys.keys
    held = RpmsRpc::Authentication.held_keys(asked)
    refute_nil held, "all keys are seeded; held_keys must not return nil"

    keys.each do |name, expected_held|
      assert_equal expected_held,
                   RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, name),
                   "has_security_key? baseline for #{name}"
      if expected_held
        assert_includes held, name, "held_keys must include seeded-held #{name}"
      else
        refute_includes held, name, "held_keys must omit seeded-unheld #{name}"
      end
    end
    assert_equal keys.select { |_, v| v }.keys, held
  end

  def test_held_keys_returns_nil_when_held_keys_context_refuses_bind
    RpmsRpc.mock! do |m|
      m.set_authenticated(SYNTHETIC_DUZ)
      m.create_context("CIAV VUECENTRIC")
      m.unbindable_context!(HELD_CONTEXT)
      m.seed(:person_has_key, [ SYNTHETIC_DUZ, "SYNKEYA" ], true)
    end

    assert_nil RpmsRpc::Authentication.held_keys([ "SYNKEYA" ])
    assert_empty nphaskey_calls(RpmsRpc.client)
    refute_equal "OR CPRS GUI CHART", RpmsRpc.client.current_context
  end

  def test_two_data_lines_in_nphaskey_reply_returns_nil
    RpmsRpc.mock! do |m|
      m.set_authenticated(SYNTHETIC_DUZ)
      m.seed_raw_lines(:person_has_key, SYNTHETIC_DUZ, %w[1 0])
    end

    assert_nil RpmsRpc::Authentication.held_keys([ "SYNKEYA" ])
  end

  # held_keys must read DUZ under the wire lock / inside the bound context (rpms-rpc#521 r2).
  class RebindBeforeLockMockClient < RpmsRpc::MockClient
    REPLACEMENT_DUZ = "900002"

    def with_context(option_name, &block)
      set_authenticated(REPLACEMENT_DUZ)
      super(option_name, &block)
    end
  end

  def test_held_keys_uses_duz_read_under_context_lock_not_before
    client = RebindBeforeLockMockClient.new
    client.set_authenticated(SYNTHETIC_DUZ)
    client.seed(:person_has_key, [ SYNTHETIC_DUZ, "SYNKEYA" ], true)
    client.seed(:person_has_key, [ RebindBeforeLockMockClient::REPLACEMENT_DUZ, "SYNKEYA" ], false)
    RpmsRpc.configure { |cfg| cfg.client = client }

    assert_equal [], RpmsRpc::Authentication.held_keys([ "SYNKEYA" ])

    calls = nphaskey_calls(client)
    refute_empty calls
    assert calls.all? { |c| c[:params].first == RebindBeforeLockMockClient::REPLACEMENT_DUZ },
           "every ORWU NPHASKEY must use the DUZ visible inside with_context"
  end

  class CallRpcOnlyDouble
    def initialize
      @calls = []
    end

    attr_reader :calls

    def call_rpc(*args)
      @calls << args
      RpmsRpc::Reply.from_wire([ "1" ])
    end

    def with_context(_option_name, &block)
      block.call
    end
  end

  def test_held_keys_returns_nil_when_client_has_no_duz_method
    double = CallRpcOnlyDouble.new
    RpmsRpc.configure { |cfg| cfg.client = double }

    assert_nil RpmsRpc::Authentication.held_keys([ "SYNKEYA" ])
    assert_empty double.calls
  end

  SYN_APP_CTX = "SYN APP CTX"
  SYN_REFUSED_CTX = "SYN REFUSED"

  # MockClient must mirror Client#create_context: a refused bind clears belief (rpms-rpc#521 r3).
  def test_mock_raw_refused_create_context_clears_current_context
    mock = RpmsRpc::MockClient.new
    mock.set_authenticated(SYNTHETIC_DUZ)
    mock.create_context(SYN_APP_CTX)
    mock.unbindable_context!(SYN_REFUSED_CTX)

    assert_raises(RpmsRpc::Client::RpcError) { mock.create_context(SYN_REFUSED_CTX) }

    assert_nil mock.current_context,
               "MockClient must clear current_context on refused create_context, same as Client"
  end

  def test_mock_with_context_refused_restores_previous_and_records_bind
    mock = RpmsRpc::MockClient.new
    mock.set_authenticated(SYNTHETIC_DUZ)
    mock.create_context(SYN_APP_CTX)
    mock.unbindable_context!(SYN_REFUSED_CTX)
    binds_before = mock.context_binds.dup
    block_ran = false

    assert_raises(RpmsRpc::Client::RpcError) do
      mock.with_context(SYN_REFUSED_CTX) { block_ran = true }
    end

    refute block_ran
    assert_equal SYN_APP_CTX, mock.current_context
    assert_equal binds_before + [ SYN_APP_CTX ], mock.context_binds,
                 "with_context ensure must re-bind the previous context after scope entry refusal"
  end
end
