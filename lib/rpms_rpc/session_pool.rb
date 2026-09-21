# frozen_string_literal: true

require "monitor"

module RpmsRpc
  # A bounded pool of broker clients keyed by an opaque session key. Each
  # authenticated session gets its OWN client, bound to that one identity for
  # its whole life in the pool — see ADR 0005 (rpms-rpc#234).
  #
  # The security core: a client built for session A is never handed to session
  # B. There is no re-authenticate-in-place path, so no reset bug can leak one
  # identity into another's request. Isolation is structural.
  #
  #   pool = RpmsRpc::SessionPool.new(
  #     max_sessions: 64,
  #     build: ->(session_key) { authenticated_client_for(session_key) }
  #   )
  #   pool.with_client(session_key) { |client| client.call_rpc(...) }
  #
  # `build` owns credentials and authentication; the pool owns only lifecycle
  # (reuse, capacity, idle eviction, shutdown). Concurrent callers for the SAME
  # session share the one client — the client serializes its own wire, and they
  # are the same identity. Eviction only drops idle entries (no in-flight call)
  # and disconnects them first.
  class SessionPool
    # Raised when every session slot is full and in use. Fail closed — never
    # silently reuse another session's client, never block forever.
    class PoolExhaustedError < StandardError; end

    # `refcount` is the number of callers currently inside with_client for this
    # entry; an entry is idle (evictable) only at 0.
    Entry = Struct.new(:client, :session_key, :refcount, :last_used_at, keyword_init: true)

    DEFAULT_MAX_SESSIONS = 64

    def initialize(max_sessions: DEFAULT_MAX_SESSIONS, build:,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @max = Integer(max_sessions)
      raise ArgumentError, "max_sessions must be positive" unless @max.positive?
      raise ArgumentError, "build must be callable" unless build.respond_to?(:call)

      @build = build
      @clock = clock
      @entries = {} # session_key => Entry
      @monitor = Monitor.new
    end

    # Check out the client for `session_key` (building + authenticating it via
    # `build` on first use), yield it, and check it back in. The client is
    # returned to the pool for reuse, not disconnected, so the session's next
    # request rides the same authenticated identity.
    def with_client(session_key)
      raise ArgumentError, "session_key required" if session_key.nil?

      entry = checkout(session_key)
      begin
        yield entry.client
      ensure
        checkin(entry)
      end
    end

    # Number of sessions currently held (idle + in use).
    def size
      @monitor.synchronize { @entries.size }
    end

    # True if a client is currently pooled for this session.
    def include?(session_key)
      @monitor.synchronize { @entries.key?(session_key) }
    end

    # Drop and disconnect every idle client. In-use entries are left alone;
    # a caller inside with_client keeps its client until it checks back in.
    # Returns the number of entries evicted.
    def shutdown
      @monitor.synchronize do
        idle = @entries.values.select { |e| e.refcount.zero? }
        idle.each { |e| drop(e) }
        idle.size
      end
    end

    private

    def checkout(session_key)
      # Build outside the lock — authentication does broker I/O and must not
      # freeze every other session's checkout. Reserve the slot first so we
      # respect capacity, then fill it.
      reserved = nil
      @monitor.synchronize do
        existing = @entries[session_key]
        if existing
          existing.refcount += 1
          existing.last_used_at = @clock.call
          return existing
        end

        make_room_or_raise
        reserved = Entry.new(client: nil, session_key: session_key, refcount: 1, last_used_at: @clock.call)
        @entries[session_key] = reserved
      end

      begin
        reserved.client = @build.call(session_key)
      rescue StandardError
        # A failed build must not leave a poisoned, clientless slot behind.
        @monitor.synchronize { @entries.delete(session_key) if @entries[session_key].equal?(reserved) }
        raise
      end
      reserved
    end

    def checkin(entry)
      @monitor.synchronize do
        entry.refcount -= 1 if entry.refcount.positive?
        entry.last_used_at = @clock.call
      end
    end

    # Caller holds the monitor. Evict the least-recently-used IDLE entry to fit
    # a new session; raise if the pool is full and nothing is idle.
    def make_room_or_raise
      return if @entries.size < @max

      victim = @entries.values.select { |e| e.refcount.zero? }.min_by(&:last_used_at)
      raise PoolExhaustedError, "session pool full (#{@max} in use)" unless victim

      drop(victim)
    end

    # Caller holds the monitor. Remove an entry and disconnect its client,
    # never raising out of teardown.
    def drop(entry)
      @entries.delete(entry.session_key)
      entry.client&.disconnect
    rescue StandardError
      nil
    end
  end
end
