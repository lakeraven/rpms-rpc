# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/session_pool"

class RpmsRpc::SessionPoolTest < Minitest::Test
  Pool = RpmsRpc::SessionPool

  # A stand-in broker client: records whether it was disconnected, and which
  # session key it was built for.
  class FakeClient
    attr_reader :session_key
    attr_reader :disconnected

    def initialize(session_key)
      @session_key = session_key
      @disconnected = false
    end

    def disconnect = @disconnected = true
  end

  # Build proc that mints a distinct client per call and counts builds per key.
  def counting_builder
    @builds = Hash.new(0)
    ->(key) { @builds[key] += 1; FakeClient.new(key) }
  end

  def test_builds_a_client_bound_to_the_session_key
    pool = Pool.new(max_sessions: 4, build: counting_builder)
    seen = nil
    pool.with_client("sess-A") { |c| seen = c }
    assert_equal "sess-A", seen.session_key
  end

  def test_same_session_reuses_the_same_client
    pool = Pool.new(max_sessions: 4, build: counting_builder)
    first = nil
    second = nil
    pool.with_client("sess-A") { |c| first = c }
    pool.with_client("sess-A") { |c| second = c }
    assert_same first, second
    assert_equal 1, @builds["sess-A"], "a reused session must not rebuild/re-authenticate"
  end

  def test_distinct_sessions_get_distinct_clients
    pool = Pool.new(max_sessions: 4, build: counting_builder)
    a = nil
    b = nil
    pool.with_client("sess-A") { |c| a = c }
    pool.with_client("sess-B") { |c| b = c }
    refute_same a, b
    assert_equal "sess-A", a.session_key
    assert_equal "sess-B", b.session_key
  end

  def test_a_client_is_never_handed_to_another_session
    # The core isolation invariant: whatever client a session gets, its bound
    # key always matches the session that checked it out.
    pool = Pool.new(max_sessions: 8, build: counting_builder)
    %w[u1 u2 u3 u4].each do |key|
      pool.with_client(key) { |c| assert_equal key, c.session_key }
    end
  end

  def test_lru_idle_client_is_evicted_and_disconnected_at_capacity
    pool = Pool.new(max_sessions: 2, build: counting_builder)
    evicted = nil
    pool.with_client("old") { |c| evicted = c }  # last_used oldest
    pool.with_client("mid") { |_c| }
    refute evicted.disconnected, "still within capacity"

    pool.with_client("new") { |_c| }             # forces eviction of LRU idle ("old")
    assert evicted.disconnected, "the LRU idle client must be disconnected on eviction"
    refute pool.include?("old")
    assert pool.include?("mid")
    assert pool.include?("new")
  end

  def test_exhaustion_when_all_slots_in_use_fails_closed
    pool = Pool.new(max_sessions: 1, build: counting_builder)
    error = nil
    pool.with_client("held") do
      error = assert_raises(RpmsRpc::SessionPool::PoolExhaustedError) do
        pool.with_client("other") { |_c| flunk "should not have checked out" }
      end
    end
    assert_match(/full/, error.message)
  end

  def test_in_use_client_is_not_evicted
    pool = Pool.new(max_sessions: 1, build: counting_builder)
    held = nil
    pool.with_client("held") do |c|
      held = c
      assert_raises(RpmsRpc::SessionPool::PoolExhaustedError) { pool.with_client("intruder") { |_c| } }
    end
    refute held.disconnected, "a checked-out client must never be evicted/disconnected"
  end

  def test_failed_build_leaves_no_poisoned_slot
    boom = ->(_key) { raise "auth failed" }
    pool = Pool.new(max_sessions: 2, build: boom)
    assert_raises(RuntimeError) { pool.with_client("sess-A") { |_c| } }
    assert_equal 0, pool.size, "a failed build must not leave a clientless slot behind"
    refute pool.include?("sess-A")
  end

  def test_concurrent_same_session_callers_share_one_client
    pool = Pool.new(max_sessions: 4, build: counting_builder)
    clients = Queue.new
    gate = Queue.new
    threads = 2.times.map do
      Thread.new do
        pool.with_client("shared") do |c|
          clients << c
          gate.pop # hold the checkout open so both are in-use at once
        end
      end
    end
    sleep 0.05
    2.times { gate << :go }
    threads.each(&:join)
    a = clients.pop
    b = clients.pop
    assert_same a, b, "concurrent same-session callers must share one client"
    assert_equal 1, @builds["shared"], "same session must authenticate once"
  end

  def test_shutdown_disconnects_idle_clients
    pool = Pool.new(max_sessions: 4, build: counting_builder)
    a = nil
    pool.with_client("sess-A") { |c| a = c }
    assert_equal 1, pool.shutdown
    assert a.disconnected
    assert_equal 0, pool.size
  end

  def test_eviction_prefers_least_recently_used
    clock = 0.0
    pool = Pool.new(max_sessions: 2, build: counting_builder, clock: -> { clock })
    older = nil
    newer = nil
    clock = 1.0
    pool.with_client("older") { |c| older = c }
    clock = 2.0
    pool.with_client("newer") { |c| newer = c }
    clock = 3.0
    pool.with_client("newest") { |_c| } # evicts "older" (lru)
    assert older.disconnected
    refute newer.disconnected
  end

  def test_max_sessions_must_be_positive
    assert_raises(ArgumentError) { Pool.new(max_sessions: 0, build: ->(_k) { nil }) }
  end

  def test_build_must_be_callable
    assert_raises(ArgumentError) { Pool.new(max_sessions: 2, build: "not callable") }
  end

  def test_nil_session_key_is_rejected
    pool = Pool.new(max_sessions: 2, build: counting_builder)
    assert_raises(ArgumentError) { pool.with_client(nil) { |_c| } }
  end
end
