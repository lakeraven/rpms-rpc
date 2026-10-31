# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/xwb_client"
require "rpms_rpc/xwb_cipher"
require "rpms_rpc/api/authentication"

# CRCONTXT^XWBSEC (pinned /data/r/XWBSEC.m:30-41) begins with K XQY0,XQY, so a
# refused XWB CREATE CONTEXT leaves the broker session with NO context. Client
# must not keep believing the pre-refusal option name (rpms-rpc#521 r2).
class RpmsRpc::ClientCreateContextRefusedTest < Minitest::Test
  SYN_APP_CTX = "SYN APP CTX"
  SYN_OTHER_CTX = "SYN OTHER CTX"
  SYN_OUTER_CTX = "SYN OUTER"
  SYN_INNER_CTX = "SYN INNER"
  SYN_REFUSED_CTX = "SYN REFUSED"

  # Models CRCONTXT: every bind first kills broker context; only @allowed binds succeed.
  class FakeXwb < RpmsRpc::XwbClient
    attr_reader :broker_ctx, :log

    def initialize(allowed: nil, start: SYN_APP_CTX)
      super()
      @connected = true
      @allowed = allowed || [ SYN_APP_CTX ]
      @broker_ctx = start
      @current_context = start
      @log = []
    end

    def connected? = true

    def call_rpc_raw(name, *params)
      @log << name
      if name == "XWB CREATE CONTEXT"
        opt = decrypt_context_param(params.first)
        @broker_ctx = nil
        return "The context '#{opt}' is not in your menu." unless @allowed.include?(opt)

        @broker_ctx = opt
        return "1"
      end

      raise "unexpected RPC #{name.inspect}"
    end

    def call_rpc(name, *_params)
      @log << name
      raise RpmsRpc::Client::RpcError, "Application context has not been created!" if broker_ctx.nil?

      RpmsRpc::Reply.from_wire([ "1" ])
    end

    private

    def decrypt_context_param(param)
      RpmsRpc::XwbCipher.decrypt(param)
    rescue StandardError
      param.to_s
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_refused_create_context_clears_client_belief_of_bound_context
    client = FakeXwb.new
    client.set_authenticated("900001")
    client.instance_variable_set(:@current_context, SYN_APP_CTX)

    assert_raises(RpmsRpc::Client::RpcError) { client.create_context(SYN_OTHER_CTX) }

    assert_nil client.current_context,
               "after a refused bind the client must not believe the old context is still bound"
    assert_nil client.broker_ctx, "broker session must have no context after CRCONTXT refusal"
  end

  def test_after_refused_bind_with_context_rebinds_stale_name
    client = FakeXwb.new
    client.set_authenticated("900001")
    client.instance_variable_set(:@current_context, SYN_APP_CTX)

    assert_raises(RpmsRpc::Client::RpcError) { client.create_context(SYN_OTHER_CTX) }

    reply = client.with_context(SYN_APP_CTX) { client.call_rpc("SYN NEXT RPC") }

    assert_equal [ "1" ], reply.to_a
    assert_equal SYN_APP_CTX, client.broker_ctx
    assert_includes client.log, "XWB CREATE CONTEXT"
  end

  def test_nested_with_context_inner_refused_restores_caller_context
    client = FakeXwb.new(allowed: [ SYN_APP_CTX, SYN_OUTER_CTX ], start: SYN_APP_CTX)
    client.set_authenticated("900001")

    assert_raises(RpmsRpc::Client::RpcError) do
      client.with_context(SYN_OUTER_CTX) { client.with_context(SYN_INNER_CTX) { :never } }
    end

    assert_equal SYN_APP_CTX, client.current_context,
                 "outer scope must re-bind the session context held before SYN OUTER"
    assert_equal SYN_APP_CTX, client.broker_ctx,
                 "broker must match client after outer ensure restores SYN APP CTX"

    reply = client.call_rpc("SYN HOST NEXT RPC")
    assert_equal [ "1" ], reply.to_a
  end

  def test_held_keys_after_refused_scope_bind_restores_xwb_session_context
    client = FakeXwb.new(allowed: [ SYN_APP_CTX ], start: SYN_APP_CTX)
    client.set_authenticated("900001")
    RpmsRpc.configure { |cfg| cfg.client = client }

    assert_nil RpmsRpc::Authentication.held_keys([ "SYNKEYA" ]),
                 "held_keys must return nil when OR CPRS GUI CHART cannot be bound"

    assert_equal SYN_APP_CTX, client.current_context,
                 "held_keys scope must restore the caller context after its bind is refused"
    assert_equal SYN_APP_CTX, client.broker_ctx

    reply = client.call_rpc("SYN HOST NEXT RPC")
    assert_equal [ "1" ], reply.to_a
  end

  def test_with_context_refused_scope_entry_restores_caller_context_on_xwb
    client = FakeXwb.new(allowed: [ SYN_APP_CTX ], start: SYN_APP_CTX)
    client.set_authenticated("900001")
    block_ran = false

    assert_raises(RpmsRpc::Client::RpcError) do
      client.with_context(SYN_REFUSED_CTX) { block_ran = true }
    end

    refute block_ran, "refused scope entry must not run the block"
    assert_equal SYN_APP_CTX, client.current_context
    assert_equal SYN_APP_CTX, client.broker_ctx

    reply = client.call_rpc("SYN HOST NEXT RPC")
    assert_equal [ "1" ], reply.to_a
  end

  def test_with_context_refused_when_restore_bind_also_refused_leaves_nil_not_stale
    client = FakeXwb.new(allowed: [], start: SYN_APP_CTX)
    client.set_authenticated("900001")

    assert_raises(RpmsRpc::Client::RpcError) do
      client.with_context(SYN_REFUSED_CTX) { }
    end

    assert_nil client.current_context,
               "must not keep believing SYN APP CTX when restore re-bind is also refused"
    assert_nil client.broker_ctx
  end
end
