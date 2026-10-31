# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/xwb_client"
require "rpms_rpc/xwb_cipher"

# CRCONTXT^XWBSEC (pinned /data/r/XWBSEC.m:30-41) begins with K XQY0,XQY, so a
# refused XWB CREATE CONTEXT leaves the broker session with NO context. Client
# must not keep believing the pre-refusal option name (rpms-rpc#521 r2).
class RpmsRpc::ClientCreateContextRefusedTest < Minitest::Test
  SYN_APP_CTX = "SYN APP CTX"
  SYN_OTHER_CTX = "SYN OTHER CTX"

  # Models CRCONTXT: a refused bind clears broker context before answering.
  class FakeXwb < RpmsRpc::XwbClient
    attr_reader :broker_ctx, :log

    def initialize
      super
      @connected = true
      @broker_ctx = SYN_APP_CTX
      @log = []
    end

    def connected? = true

    def call_rpc_raw(name, *params)
      @log << name
      if name == "XWB CREATE CONTEXT"
        opt = decrypt_context_param(params.first)
        @broker_ctx = nil
        return "The context '#{opt}' is not in your menu." unless opt == SYN_APP_CTX

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
end
