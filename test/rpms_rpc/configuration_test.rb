# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"

class RpmsRpc::ConfigurationTest < Minitest::Test
  def teardown
    RpmsRpc.reset!
  end

  # -- configure + client ----------------------------------------------------

  # Any object can be the client; the fetch paths through it are in
  # fetch_api_test.rb, over captured replies.
  def test_configure_sets_client
    client = Object.new
    RpmsRpc.configure { |c| c.client = client }

    assert_same client, RpmsRpc.client
  end

  def test_client_raises_when_not_configured
    assert_raises(RpmsRpc::NotConfiguredError) { RpmsRpc.client }
  end

  def test_reset_clears_client
    RpmsRpc.configure { |c| c.client = Object.new }
    RpmsRpc.reset!
    assert_raises(RpmsRpc::NotConfiguredError) { RpmsRpc.client }
  end

  # -- module-level synchronize_wire must FAIL CLOSED ------------------------

  # A client that forwards call_rpc but does not define synchronize_wire
  # (a wrapper / delegator) used to make RpmsRpc.synchronize_wire yield
  # UNLOCKED. That is weaker than the pre-0.3.0 world, where the absence of
  # the method was VISIBLE to callers (respond_to? false → their own mutex
  # fallback). Post-0.3.0 the module method exists, so #486's respond_to?
  # guard is vacuously true and its fallback is dead code — a non-conforming
  # client would then unlock silently. The module path must serialize
  # regardless, with a process-wide fallback lock.
  class WireLocklessClient
    attr_reader :log

    def initialize
      @log = []
      @mutex = Mutex.new
    end

    # NOT synchronize_wire — this stands in for a wrapper that only forwards
    # the RPC surface.
    def call_rpc(_name, *_params)
      @mutex.synchronize { @log << :enter }
      sleep 0.02
      @mutex.synchronize { @log << :exit }
    end
  end

  def test_module_synchronize_wire_fails_closed_for_a_lockless_client
    client = WireLocklessClient.new
    refute client.respond_to?(:synchronize_wire), "precondition: client has no wire lock of its own"
    RpmsRpc.configure { |c| c.client = client }

    threads = Array.new(4) do
      Thread.new { RpmsRpc.synchronize_wire { client.call_rpc("X") } }
    end
    threads.each(&:join)

    # Serialized: every enter is immediately followed by its own exit.
    client.log.each_slice(2) do |enter, exit|
      assert_equal [ :enter, :exit ], [ enter, exit ],
        "RpmsRpc.synchronize_wire yielded UNLOCKED for a client without its own " \
        "wire lock: #{client.log.inspect}"
    end
  end

  # -- fetch without a client ---------------------------------------------

  def test_fetch_one_raises_when_not_configured
    assert_raises(RpmsRpc::NotConfiguredError) do
      RpmsRpc::DataMapper.patient_select.fetch_one("1")
    end
  end
end
