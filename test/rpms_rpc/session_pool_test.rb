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

  # The first-touch race (PR #250 review): a second caller for the SAME new
  # session must not be handed a half-built (nil) client while the first
  # caller is still authenticating. Forces both threads into checkout with a
  # build that blocks until released, so the second is genuinely mid-build —
  # a real broker sign-on's I/O latency, not an instant fake.
  def test_concurrent_first_touch_never_yields_a_nil_client
    build_started = Queue.new
    release_build = Queue.new
    builds = 0
    count_lock = Mutex.new
    blocking_build = lambda do |key|
      count_lock.synchronize { builds += 1 }
      build_started << :started
      release_build.pop # hold the build open until the test lets it finish
      FakeClient.new(key)
    end
    pool = Pool.new(max_sessions: 4, build: blocking_build)

    seen = Queue.new
    a = Thread.new { pool.with_client("s") { |c| seen << c } }
    build_started.pop           # A is mid-build: entry exists, client still nil
    b = Thread.new { pool.with_client("s") { |c| seen << c } }
    sleep 0.05                  # let B reach the wait on the building entry
    release_build << :go        # A's build completes and signals waiters
    a.join
    b.join

    first = seen.pop
    second = seen.pop
    refute_nil first, "a same-session caller must never be yielded a nil client"
    refute_nil second, "a same-session caller must never be yielded a nil client"
    assert_same first, second, "both callers must share the one built client"
    assert_equal 1, builds, "the second caller must reuse the build, not start its own"
  end

  # A failed build must wake same-session waiters so one of them retries,
  # rather than leaving them blocked forever on a build that never completes.
  def test_failed_build_wakes_waiters_who_then_retry
    attempts = 0
    count_lock = Mutex.new
    first_started = Queue.new
    release_first = Queue.new
    build = lambda do |key|
      n = count_lock.synchronize { attempts += 1 }
      if n == 1
        first_started << :started
        release_first.pop
        raise "first build fails"
      end
      FakeClient.new(key)
    end
    pool = Pool.new(max_sessions: 4, build: build)

    errors = Queue.new
    results = Queue.new
    a = Thread.new do
      pool.with_client("s") { |c| results << c }
    rescue StandardError => e
      errors << e
    end
    first_started.pop            # A is mid-(doomed)-build; entry exists, nil client
    b = Thread.new { pool.with_client("s") { |c| results << c } }
    sleep 0.05                   # B waits on the building entry
    release_first << :go         # A's build raises, removes the entry, wakes B
    a.join
    b.join

    assert_equal 1, errors.size, "the builder whose build failed surfaces the error"
    refute_nil results.pop, "the waiter retries the build and gets a real client"
    assert_equal 2, attempts, "the waiter took over the build after the first failed"
  end

  # A non-StandardError from build (the reason checkout uses ensure, not
  # rescue StandardError) must still drop the slot and wake waiters — never
  # leave a same-session waiter blocked forever.
  def test_non_standard_error_in_build_still_wakes_waiters
    boom = Class.new(Exception)
    attempts = 0
    lock = Mutex.new
    started = Queue.new
    release = Queue.new
    build = lambda do |key|
      n = lock.synchronize { attempts += 1 }
      if n == 1
        started << :s
        release.pop
        raise boom, "non-standard build failure"
      end
      FakeClient.new(key)
    end
    pool = Pool.new(max_sessions: 4, build: build)

    results = Queue.new
    a = Thread.new do
      Thread.current.report_on_exception = false
      pool.with_client("s") { |c| results << c }
    rescue boom
      results << :boom
    end
    started.pop
    b = Thread.new { pool.with_client("s") { |c| results << c } }
    sleep 0.05
    release << :go
    assert a.join(5), "builder thread did not finish"
    assert b.join(5), "waiter hung — ensure must wake waiters even on a non-StandardError"

    got = [ results.pop, results.pop ]
    assert_includes got, :boom
    assert(got.any? { |x| x.is_a?(FakeClient) }, "the waiter must retake the build and get a real client")
    assert_equal 2, attempts
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
