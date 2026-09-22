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

  def test_with_client_returns_the_adopted_client_without_building
    pool = Pool.new(max_sessions: 4, build: counting_builder)
    adopted = FakeClient.new("sess-A")
    assert_same adopted, pool.adopt("sess-A", adopted)

    pool.with_client("sess-A") { |c| assert_same adopted, c }
    assert_equal 0, @builds["sess-A"], "an adopted session must not re-authenticate"
    refute adopted.disconnected

    pool.with_client("sess-B") { |c| assert_equal "sess-B", c.session_key }
    assert_equal 1, @builds["sess-B"], "a key that was not adopted still builds"
    refute_same adopted, pool.with_client("sess-B") { |c| c }
  end

  def test_concurrent_with_client_reuses_the_adopted_client_without_building
    # A nil client on the adopted entry would park both callers on @build_done
    # forever: nobody is in build to broadcast. join must return.
    pool = Pool.new(max_sessions: 4, build: counting_builder)
    adopted = FakeClient.new("shared")
    pool.adopt("shared", adopted)
    clients = Queue.new
    gate = Queue.new
    threads = 2.times.map do
      Thread.new do
        pool.with_client("shared") do |c|
          clients << c
          gate.pop
        end
      end
    end
    begin
      sleep 0.05
      2.times { gate << :go }
      finish_threads(threads)
    ensure
      2.times { gate << :go }
    end
    assert_same adopted, clients.pop
    assert_same adopted, clients.pop
    assert_equal 0, @builds["shared"], "sharing an adopted client must not build"
  end

  def test_adopt_rejects_a_nil_key_and_a_nil_client
    pool = Pool.new(max_sessions: 2, build: counting_builder)
    client = FakeClient.new("a")
    assert_raises(ArgumentError) { pool.adopt(nil, client) }
    assert_raises(ArgumentError) { pool.adopt("a", nil) }
    assert_equal 0, pool.size, "a rejected adopt must not reserve a slot"
    refute client.disconnected, "a rejected adopt must not disconnect the caller's client"
  end

  def test_adopt_into_an_occupied_key_keeps_the_original_client
    pool = Pool.new(max_sessions: 4, build: counting_builder)
    original = FakeClient.new("a")
    replacement = FakeClient.new("a2")
    pool.adopt("a", original)

    assert_raises(Pool::SessionOccupiedError) { pool.adopt("a", replacement) }
    refute original.disconnected, "refusing a re-bind must not disconnect the live client"
    refute replacement.disconnected, "a refused client stays the caller's to disconnect"
    assert pool.include?("a")
    pool.with_client("a") { |c| assert_same original, c }
    assert_equal 0, @builds["a"]
  end

  # max 2 with a free slot: capacity must not be what saves the in-use client.
  # A guard that only rejects idle keys would overwrite this entry in place.
  def test_adopt_into_an_in_use_key_does_not_replace_the_checked_out_client
    pool = Pool.new(max_sessions: 2, build: counting_builder)
    held = FakeClient.new("held")
    intruder = FakeClient.new("intruder")
    pool.adopt("held", held)

    pool.with_client("held") do |c|
      assert_raises(Pool::SessionOccupiedError) { pool.adopt("held", intruder) }
      pool.with_client("held") { |inner| assert_same c, inner }
      refute c.disconnected, "an in-use client must not be disconnected out from under its caller"
      refute intruder.disconnected
    end
    pool.with_client("held") { |c| assert_same held, c }
    assert_equal 0, @builds["held"]
  end

  def test_adopt_rejects_a_client_already_bound_to_another_key
    pool = Pool.new(max_sessions: 4, build: counting_builder)
    client = FakeClient.new("a")
    pool.adopt("a", client)

    assert_raises(Pool::SessionOccupiedError) { pool.adopt("b", client) }
    refute pool.include?("b"), "one client must not be aliased onto a second session"
    refute client.disconnected
    pool.with_client("a") { |c| assert_same client, c }
    assert_equal 0, @builds["b"], "the refused key must not fall through into build"
  end

  # The bound client is the only slot and it is idle, so a check that runs
  # AFTER eviction would disconnect it and then re-bind that same object.
  def test_rebind_does_not_evict_the_client_already_bound_at_capacity
    pool = Pool.new(max_sessions: 1, build: counting_builder)
    client = FakeClient.new("a")
    pool.adopt("a", client)

    assert_raises(Pool::SessionOccupiedError) { pool.adopt("b", client) }
    refute client.disconnected, "the identity check must run before eviction disconnects this client"
    assert pool.include?("a"), "a refused re-bind must leave the original session in the pool"
    refute pool.include?("b")
    pool.with_client("a") { |c| assert_same client, c }
  end

  def test_refused_adopt_does_not_evict_a_bystander
    clock = 0.0
    pool = Pool.new(max_sessions: 2, build: counting_builder, clock: -> { clock })
    clock = 1.0
    bystander = FakeClient.new("bystander")
    pool.adopt("bystander", bystander) # LRU, so an eviction-first adopt would drop it
    clock = 2.0
    original = FakeClient.new("target")
    pool.adopt("target", original)
    clock = 3.0
    replacement = FakeClient.new("target-2")

    assert_raises(Pool::SessionOccupiedError) { pool.adopt("target", replacement) }
    refute bystander.disconnected, "a refused adopt must not disconnect some other session"
    refute original.disconnected
    refute replacement.disconnected
    assert pool.include?("bystander"), "a refused adopt must not drop another session to make room"
    assert pool.include?("target")
    pool.with_client("target") { |c| assert_same original, c }
  end

  def test_adopt_evicts_the_lru_idle_client_at_capacity
    clock = 0.0
    pool = Pool.new(max_sessions: 2, build: counting_builder, clock: -> { clock })
    clock = 1.0
    older = nil
    pool.with_client("older") { |c| older = c }
    clock = 2.0
    newer = nil
    pool.with_client("newer") { |c| newer = c }
    clock = 3.0
    fresh = FakeClient.new("fresh")

    pool.adopt("fresh", fresh)
    assert older.disconnected, "the LRU idle client is the one eviction disconnects"
    refute newer.disconnected
    refute fresh.disconnected
    refute pool.include?("older")
    assert pool.include?("newer")
    assert pool.include?("fresh")
    pool.with_client("fresh") { |c| assert_same fresh, c }
    assert_equal 0, @builds["fresh"]
  end

  def test_adopt_fails_closed_when_every_session_is_in_use
    pool = Pool.new(max_sessions: 1, build: counting_builder)
    held = nil
    incoming = FakeClient.new("incoming")
    error = nil
    pool.with_client("held") do |c|
      held = c
      error = assert_raises(Pool::PoolExhaustedError) { pool.adopt("incoming", incoming) }
    end
    assert_match(/full/, error.message)
    refute held.disconnected, "exhaustion must not disconnect the in-use client"
    refute incoming.disconnected, "a refused client stays the caller's"
    refute pool.include?("incoming")
    assert pool.include?("held")
  end

  def test_shutdown_disconnects_an_adopted_idle_client
    pool = Pool.new(max_sessions: 4, build: counting_builder)
    adopted = FakeClient.new("sess-A")
    pool.adopt("sess-A", adopted)
    assert_equal 1, pool.shutdown
    assert adopted.disconnected, "after adopt the pool owns idle disconnect"
    assert_equal 0, pool.size
  end

  # Hash#[]= copies and freezes its own key, so a lookup by the original
  # string still hits. Eviction and shutdown delete through Entry#session_key.
  # If that is the caller's object, mutating it makes the delete miss and the
  # disconnected client stays checked-out-able.
  def test_caller_cannot_retarget_an_adopted_session_by_mutating_the_key
    pool = Pool.new(max_sessions: 2, build: counting_builder)
    key = "sess-A".dup
    client = FakeClient.new("sess-A")
    pool.adopt(key, client)
    key << "-mutated"

    pool.with_client("sess-A") { |c| assert_same client, c }
    assert_equal 0, @builds["sess-A"]
    assert_equal 1, pool.shutdown
    assert client.disconnected
    assert_equal 0, pool.size, "mutating the caller's key must not leave the entry in the map"
    refute pool.include?("sess-A")
  end

  def test_concurrent_adopts_of_one_key_bind_exactly_one_client
    pool = Pool.new(max_sessions: 4, build: counting_builder)
    clients = [ FakeClient.new("one"), FakeClient.new("two") ]
    ready = Queue.new
    go = Queue.new
    threads = clients.each_with_index.map do |client, index|
      Thread.new do
        ready << :up
        go.pop
        pool.adopt("same", client)
        [ :ok, index ]
      rescue Pool::SessionOccupiedError
        [ :occupied, index ]
      end
    end
    begin
      2.times { ready.pop }
      2.times { go << :go }
      finish_threads(threads)
    ensure
      2.times { go << :go }
    end

    outcomes = threads.map(&:value)
    winners = outcomes.select { |kind, _index| kind == :ok }
    assert_equal 1, winners.size, "exactly one adopt may bind a key"
    winner = clients[winners[0][1]]
    loser = clients[1 - winners[0][1]]
    refute loser.disconnected, "the refused adopt must not disconnect the caller's client"
    refute winner.disconnected
    pool.with_client("same") { |c| assert_same winner, c }
    assert_equal 0, @builds["same"]
  end

  # Build reserved the key and is still authenticating. adopt must not fill
  # that nil slot: the builder's ensure assigns the built client onto the
  # same entry and broadcasts. Stealing it splits the key, or hands a waiter nil.
  def test_adopt_during_build_rejects_and_waiters_get_the_built_client
    build_started = Queue.new
    release_build = Queue.new
    builds = 0
    count_lock = Mutex.new
    blocking_build = lambda do |key|
      count_lock.synchronize { builds += 1 }
      build_started << :started
      release_build.pop
      FakeClient.new(key)
    end
    pool = Pool.new(max_sessions: 4, build: blocking_build)
    intruder = FakeClient.new("intruder")
    seen = Queue.new
    builder = Thread.new { pool.with_client("s") { |c| seen << c } }
    waiter = nil
    begin
      build_started.pop
      waiter = Thread.new { pool.with_client("s") { |c| seen << c } }
      sleep 0.05
      assert_raises(Pool::SessionOccupiedError) { pool.adopt("s", intruder) }
      refute intruder.disconnected, "a client adopt refused is still the caller's"
      release_build << :go
      finish_threads([ builder, waiter ])
    ensure
      release_build << :go
    end

    first = seen.pop
    second = seen.pop
    refute_nil first, "a same-session caller must never be yielded a nil client"
    refute_nil second, "a same-session caller must never be yielded a nil client"
    assert_same first, second, "builder and waiter must share the one built client"
    refute_same first, intruder, "the refused client must not become the session's client"
    assert_equal 1, builds, "the waiter must not start a second build"
    pool.with_client("s") { |c| assert_same first, c }
  end

  # Same window, but the in-flight build fails. adopt's refusal must not
  # consume the broadcast or delete the reservation, or the waiter hangs
  # instead of retrying.
  def test_rejected_adopt_during_failed_build_still_wakes_the_waiter
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
    intruder = FakeClient.new("intruder")
    errors = Queue.new
    results = Queue.new
    builder = Thread.new do
      pool.with_client("s") { |c| results << c }
    rescue StandardError => e
      errors << e
    end
    waiter = nil
    begin
      first_started.pop
      waiter = Thread.new { pool.with_client("s") { |c| results << c } }
      sleep 0.05
      assert_raises(Pool::SessionOccupiedError) { pool.adopt("s", intruder) }
      release_first << :go
      finish_threads([ builder, waiter ])
    ensure
      release_first << :go
    end

    refute intruder.disconnected
    assert_equal 1, errors.size, "the builder whose build failed surfaces the error"
    built = results.pop
    refute_nil built, "the waiter retries and gets a real client"
    refute_same built, intruder
    assert_equal 2, attempts, "the waiter took over the build after the first failed"
  end

  def test_adopt_refuses_a_client_an_eviction_is_disconnecting
    pool = Pool.new(max_sessions: 1, build: counting_builder)
    doomed = FakeClient.new("old")
    started, release = blocking_disconnect(doomed)
    pool.adopt("old", doomed)
    fresh = FakeClient.new("new")
    evictor = Thread.new { pool.adopt("new", fresh) }
    begin
      assert_equal :started, started.pop(timeout: 5), "eviction disconnect never started"
      assert_raises(Pool::SessionOccupiedError) { pool.adopt("rebound", doomed) }
      refute pool.include?("rebound"), "a disconnecting client must not be re-bound under a new key"
    ensure
      release << :go
    end
    finish_threads([ evictor ])

    assert doomed.disconnected
    refute pool.include?("old")
    refute pool.include?("rebound")
    assert pool.include?("new")
    pool.with_client("new") { |c| assert_same fresh, c }
    refute fresh.disconnected
  end

  def test_adopt_refuses_a_client_shutdown_is_disconnecting
    pool = Pool.new(max_sessions: 4, build: counting_builder)
    doomed = FakeClient.new("old")
    started, release = blocking_disconnect(doomed)
    pool.adopt("old", doomed)
    other = FakeClient.new("keep")
    pool.adopt("keep", other)

    reaper = Thread.new { pool.shutdown }
    begin
      assert_equal :started, started.pop(timeout: 5), "shutdown disconnect never started"
      assert_raises(Pool::SessionOccupiedError) { pool.adopt("rebound", doomed) }
      refute pool.include?("rebound")
    ensure
      release << :go
    end
    finish_threads([ reaper ])

    assert doomed.disconnected
    assert other.disconnected
    assert_equal 0, pool.size
    refute pool.include?("rebound")
  end

  # Join with a timeout, then kill anything still blocked. A half-built (nil)
  # entry waits on @build_done with nobody to signal; a leaked waiter would
  # hold the suite open after the assertion already failed.
  def finish_threads(threads)
    threads.each do |thread|
      assert thread.join(5), "thread hung — a waiter was not signalled, or a client looked half-built"
    end
  ensure
    threads.each { |thread| thread.kill if thread&.alive? }
  end

  # Parks disconnect until `release` is pushed, so a test can adopt while the
  # pool is inside safe_disconnect and the condemn mark must still hold.
  def blocking_disconnect(client)
    started = Queue.new
    release = Queue.new
    client.define_singleton_method(:disconnect) do
      started << :started
      release.pop
      @disconnected = true
    end
    [ started, release ]
  end
end
