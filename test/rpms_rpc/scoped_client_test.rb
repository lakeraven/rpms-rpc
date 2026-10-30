# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"

# RpmsRpc.with_client scopes RpmsRpc.client to one client for a block, so a
# host serving many users runs each request on its own user's connection with
# no API signature changes (lakeraven-ehr ADR 0011, as amended). A host that
# configures no client gets NotConfiguredError outside a scope: a forgotten
# scope fails loudly instead of borrowing another user's connection.
class RpmsRpc::ScopedClientTest < Minitest::Test
  def teardown = RpmsRpc.reset!

  def a = @a ||= Object.new
  def b = @b ||= Object.new

  def test_inside_a_scope_the_client_is_the_scoped_one
    RpmsRpc.configure { |c| c.client = b }
    RpmsRpc.with_client(a) { assert_same a, RpmsRpc.client }
    assert_same b, RpmsRpc.client, "the configured client is back outside the scope"
  end

  def test_with_no_configured_client_a_call_outside_a_scope_raises
    RpmsRpc.with_client(a) { assert_same a, RpmsRpc.client }
    assert_raises(RpmsRpc::NotConfiguredError) { RpmsRpc.client }
  end

  def test_the_scope_is_restored_when_the_block_raises
    assert_raises(RuntimeError) { RpmsRpc.with_client(a) { raise "boom" } }
    assert_nil RpmsRpc.scoped_client
  end

  def test_scopes_nest
    RpmsRpc.with_client(a) do
      RpmsRpc.with_client(b) { assert_same b, RpmsRpc.client }
      assert_same a, RpmsRpc.client
    end
  end

  def test_threads_and_fibers_started_in_a_scope_see_it_and_others_do_not
    started_before = Thread.new { sleep 0.1; RpmsRpc.scoped_client }
    RpmsRpc.with_client(a) do
      assert_same a, Thread.new { RpmsRpc.client }.value
      assert_same a, Fiber.new { RpmsRpc.client }.resume
    end
    assert_nil started_before.value
  end

  def test_two_threads_each_keep_their_own_scope
    seen = {}
    [ [ :a, a ], [ :b, b ] ].map do |name, client|
      Thread.new { RpmsRpc.with_client(client) { sleep 0.05; seen[name] = RpmsRpc.client } }
    end.each(&:join)
    assert_same a, seen[:a]
    assert_same b, seen[:b]
  end

  def test_the_wire_lock_is_the_scoped_clients_own
    locked = Struct.new(:calls) do
      def synchronize_wire = (self.calls += 1) && yield
    end.new(0)
    RpmsRpc.with_client(locked) { RpmsRpc.synchronize_wire { :ok } }
    assert_equal 1, locked.calls
  end

  def test_a_nil_client_is_refused_and_leaves_the_scope_alone
    RpmsRpc.with_client(a) do
      assert_raises(ArgumentError) { RpmsRpc.with_client(nil) { flunk "ran" } }
      assert_same a, RpmsRpc.client
    end
  end
end
