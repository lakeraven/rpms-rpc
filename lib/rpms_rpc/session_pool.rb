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
  #   pool.adopt(session_key, already_authenticated_client)
  #   pool.with_client(session_key) { |client| client.call_rpc(...) }
  #
  # Two ways in. `adopt` is the sign-on path: the host already authenticated
  # that client, and the pool holds no credentials — building again would be a
  # second sign-on. `build` is the lazy path for a key the pool has not seen.
  # Either way the pool owns only lifecycle (reuse, capacity, idle eviction,
  # shutdown). Concurrent callers for the SAME session share the one client —
  # the client serializes its own wire, and they are the same identity.
  # Eviction only drops idle entries (no in-flight call) and disconnects them
  # first.
  class SessionPool
    # Raised when every session slot is full and in use. Fail closed — never
    # silently reuse another session's client, never block forever.
    class PoolExhaustedError < StandardError; end

    # Raised when adopt would break the one-identity binding. The key is
    # already reserved (idle, in use, or mid-build), or this client object is
    # already bound to a key or condemned for disconnect. The pool does not
    # take the client. A "client is disconnecting" refusal means a
    # pool-initiated disconnect of that object is already in flight — the
    # caller must not keep using it.
    class SessionOccupiedError < StandardError; end

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
      # Removed from @entries, not yet disconnected. Disconnect runs off the
      # lock; without this set a concurrent adopt could put the client back
      # under a new key and then lose it to that disconnect.
      @pending_disconnect = {} # object_id => client
      @monitor = Monitor.new
      # Signalled when a build finishes (success or failure). Same-session
      # waiters block on it rather than observing a half-built entry.
      @build_done = @monitor.new_cond
    end

    # Check out the client for `session_key`, yield it, and check it back in.
    # First use builds via `build` unless `adopt` already placed one. The
    # client is returned to the pool for reuse, not disconnected, so the
    # session's next request rides the same authenticated identity.
    def with_client(session_key)
      raise ArgumentError, "session_key required" if session_key.nil?

      entry = checkout(freeze_key(session_key))
      begin
        yield entry.client
      ensure
        checkin(entry)
      end
    end

    # Place an already-authenticated `client` under `session_key` and return
    # it. Does not call `build`. Refcount stays 0 — adopt does not check the
    # client out; the next `with_client` does.
    #
    # Refuses, without mutating the pool, when the key is already reserved or
    # this client object is already bound. Replacing an occupied key would be
    # a second sign-on into a slot that already has an identity — the re-bind
    # ADR 0005 exists to make impossible — and an in-use entry (refcount > 0,
    # including a build still in flight) would be dropped out from under its
    # caller. A new login is a new session key.
    #
    # At capacity, evicts the LRU idle entry or raises PoolExhaustedError.
    # Those identity checks run BEFORE eviction, so a refused adopt cannot
    # disconnect a bystander, or the client being adopted, on the way out.
    # On success the pool owns the client's later disconnect; on refusal the
    # caller still does, unless the error says the client is disconnecting.
    def adopt(session_key, client)
      raise ArgumentError, "session_key required" if session_key.nil?
      raise ArgumentError, "client required" if client.nil?

      evicted = @monitor.synchronize { reserve_adopted(freeze_key(session_key), client) }
      safe_disconnect(evicted)
      client
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
    # Returns the number of entries evicted. Disconnect I/O runs OUTSIDE the
    # monitor so a wedged socket can't freeze the pool.
    def shutdown
      clients = @monitor.synchronize do
        idle = @entries.values.select { |e| e.refcount.zero? }
        idle.each do |entry|
          @entries.delete(entry.session_key)
          condemn(entry.client)
        end
        idle.map(&:client)
      end
      clients.each { |c| safe_disconnect(c) }
      clients.size
    end

    private

    # A caller-owned mutable String key, mutated after checkout, would corrupt
    # @entries. Freeze a copy so the pool owns an immutable key. Non-String
    # keys (symbols, integers) are already immutable enough.
    def freeze_key(key)
      key.is_a?(String) ? key.dup.freeze : key
    end

    # Off the lock: a wedged socket must not freeze the pool. Swallow disconnect
    # errors so one dead socket cannot abort the rest of an eviction. The
    # condemn mark stays until the attempt returns — adopt must keep refusing
    # this object for the whole call, including while disconnect blocks.
    def safe_disconnect(client)
      return unless client

      client.disconnect
    rescue StandardError
      nil
    ensure
      release_condemned(client)
    end

    # Caller holds the monitor. Insert `client` under `key`, or raise without
    # changing @entries. Returns the idle client evicted to make room (the
    # caller disconnects it off the lock), or nil.
    #
    # A mid-build entry (client still nil) is occupied too. Filling it here
    # would race the builder's ensure, which assigns `reserved.client` on that
    # same entry and then broadcasts: the adopted client gets clobbered, or
    # one key splits across two clients, and a waiter can observe nil. The
    # builder keeps the slot and the broadcast.
    def reserve_adopted(key, client)
      if @entries.key?(key)
        raise SessionOccupiedError, "session already reserved"
      end
      if @pending_disconnect.key?(client.object_id)
        raise SessionOccupiedError, "client is disconnecting"
      end
      if @entries.each_value.any? { |entry| entry.client.equal?(client) }
        raise SessionOccupiedError, "client already bound to a session"
      end

      evicted = make_room_or_raise
      @entries[key] = Entry.new(client: client, session_key: key, refcount: 0, last_used_at: @clock.call)
      evicted
    end

    # Caller holds the monitor.
    def condemn(client)
      @pending_disconnect[client.object_id] = client if client
    end

    def release_condemned(client)
      return unless client

      @monitor.synchronize { @pending_disconnect.delete(client.object_id) }
    end

    def checkout(session_key)
      # Build outside the lock — authentication does broker I/O and must not
      # freeze every other session's checkout. Reserve the slot first so we
      # respect capacity, then fill it. A concurrent same-session caller that
      # finds the entry still building WAITS for it, so it never observes a
      # half-built (client: nil) entry.
      reserved = nil
      evicted = nil
      @monitor.synchronize do
        loop do
          existing = @entries[session_key]
          if existing.nil?
            evicted = make_room_or_raise # a client to disconnect, or nil
            reserved = Entry.new(client: nil, session_key: session_key, refcount: 1, last_used_at: @clock.call)
            @entries[session_key] = reserved
            break # this thread owns the build; run it below, outside the lock
          elsif existing.client
            existing.refcount += 1
            existing.last_used_at = @clock.call
            return existing
          else
            @build_done.wait # another thread is building this key; sleep until it signals
          end
        end
      end
      safe_disconnect(evicted) # off the lock — a wedged socket must not freeze checkout

      # `ensure`, not `rescue StandardError`: a build that raises ANYTHING —
      # including a non-StandardError — must still drop the poisoned slot and
      # wake waiters, or a same-session waiter blocks on @build_done forever.
      built = nil
      begin
        built = @build.call(session_key)
      ensure
        @monitor.synchronize do
          if built
            reserved.client = built
          elsif @entries[session_key].equal?(reserved)
            @entries.delete(session_key) # build failed — let a waiter retake it
          end
          @build_done.broadcast
        end
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
    # a new session; raise if the pool is full and nothing is idle. Returns the
    # evicted client (for the caller to disconnect off the lock), or nil.
    # Condemns it before returning: the disconnect window is off the lock, and
    # adopt must not re-bind the client under a new key in that gap.
    def make_room_or_raise
      return nil if @entries.size < @max

      victim = @entries.values.select { |e| e.refcount.zero? }.min_by(&:last_used_at)
      raise PoolExhaustedError, "session pool full (#{@max} in use)" unless victim

      @entries.delete(victim.session_key)
      condemn(victim.client)
      victim.client
    end
  end
end
