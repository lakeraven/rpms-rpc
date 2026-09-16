# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/cia_client"
require "rpms_rpc/xwb_client"
require "rpms_rpc/api/authentication"
require "rpms_rpc/mock_client"

# A wire lock makes a request and its reply atomic. It does NOT by itself make
# the SESSION safe: state read before the lock is acquired, state written after
# it is released, and a socket left desynchronized by a timeout all leak across
# callers anyway. These are the reproductions for each of those.
class RpmsRpc::BrokerSessionIntegrityTest < Minitest::Test
  EOD = RpmsRpc::Client::EOD
  EOT = RpmsRpc::Client::EOT

  class RecordingSocket
    attr_reader :writes

    def initialize(reads = [])
      @reads = reads.dup
      @writes = []
    end

    def write(str) = (@writes << str) && str.bytesize
    def recv(_n) = @reads.empty? ? "" : @reads.shift
    def push_read(str) = @reads << str
    def flush; end
    def close = @closed = true
    def closed? = !!@closed
    def setsockopt(*); end
  end

  # A socket whose read blocks until released, so a timeout can be forced with
  # a real reply still in flight behind it.
  class StallingSocket < RecordingSocket
    def initialize(reads = [])
      super
      @gate = Queue.new
    end

    def recv(n)
      @gate.pop if @stall
      super
    end

    def stall! = @stall = true
    def release! = @gate << :go
  end

  def cia_client(socket)
    c = RpmsRpc::CiaClient.new
    c.instance_variable_set(:@socket, socket)
    c.instance_variable_set(:@connected, true)
    c.instance_variable_set(:@timeout, 1)
    c.instance_variable_set(:@seq, 0)
    c.instance_variable_set(:@session_uid, "1")
    c
  end

  # -- C: CIA frames are built before the monitor is acquired ---------------

  # A call issued while a sign-on is in flight assembles its frame from state
  # that the sign-on is about to replace, then waits for the lock and sends the
  # stale frame anyway. The lock protects the wire; it did not protect the
  # frame that was already built.
  def test_a_queued_call_does_not_send_a_frame_built_before_the_lock
    socket = RecordingSocket.new
    client = cia_client(socket)
    uid_rebound = Queue.new

    holder = Thread.new do
      client.synchronize_wire do
        uid_rebound << :locked
        sleep 0.15
        client.instance_variable_set(:@session_uid, "7") # what a sign-on does
      end
    end

    uid_rebound.pop
    socket.push_read("OK#{EOD}")
    caller_thread = Thread.new { client.call_rpc_raw("CIANBRPC GETVAR", "DUZ") }
    [ holder, caller_thread ].each(&:join)

    frame = socket.writes.last
    uid_field = ->(uid) { client.send(:pk, "UID") + client.send(:pk, "") + client.send(:pk, uid) }
    assert_includes frame, uid_field.call("7"),
      "the queued call sent a frame carrying the session UID it captured BEFORE the lock"
    refute_includes frame, uid_field.call("1")
  end

  # -- H: base authentication commits state after releasing the lock -------

  # A signs on and gets DUZ 301; B signs on and the broker session becomes 302;
  # A then writes @duz = 301 over it. The client's idea of who it is and the
  # broker's disagree.
  def test_base_authentication_commits_its_identity_under_the_lock
    reply_for = { "301" => "301\r\n0\r\n0\r\nWelcome\r\n", "302" => "302\r\n0\r\n0\r\nWelcome\r\n" }

    socket = RecordingSocket.new
    client = RpmsRpc::XwbClient.new
    client.instance_variable_set(:@socket, socket)
    client.instance_variable_set(:@connected, true)
    client.instance_variable_set(:@timeout, 1)

    observed = Queue.new
    client.define_singleton_method(:signon_setup) { "" }
    client.define_singleton_method(:call_rpc_raw) do |_name, *_params|
      duz = Thread.current[:duz]
      observed << duz
      reply_for[duz]
    end

    # Deterministic interleave: park A the instant it RELEASES the wire lock,
    # let B sign on end to end, then let A finish. If A commits its identity
    # after the lock, it lands on top of B's.
    released = Queue.new
    b_done = Queue.new
    original = client.method(:synchronize_wire)
    client.define_singleton_method(:synchronize_wire) do |&blk|
      result = original.call(&blk)
      if Thread.current[:duz] == "301"
        released << :released
        b_done.pop
      end
      result
    end

    a = Thread.new { Thread.current[:duz] = "301"; client.authenticate("AC", "VC") }
    released.pop
    b = Thread.new { Thread.current[:duz] = "302"; client.authenticate("AC", "VC") }
    b.join
    b_done << :go
    a.join

    broker_duz = nil
    broker_duz = observed.pop until observed.empty?
    assert_equal broker_duz, client.duz,
      "the client committed an identity the broker session no longer holds"
  end

  # -- H: a queued caller can consume a timed-out call's late reply --------

  # B passes connected? before A times out, then waits for the monitor. A's
  # read times out leaving the socket desynchronized with its reply still in
  # flight; B acquires the lock and reads A's reply as its own.
  def test_a_timed_out_call_does_not_hand_its_reply_to_the_next_caller
    socket = StallingSocket.new
    client = RpmsRpc::XwbClient.new
    client.instance_variable_set(:@socket, socket)
    client.instance_variable_set(:@connected, true)
    client.instance_variable_set(:@timeout, 0)
    socket.stall!

    timed_out = nil
    a = Thread.new do
      begin
        client.call_rpc("A RPC")
      rescue StandardError => e
        timed_out = e
      end
    end
    a.join

    refute_nil timed_out, "the first call should have timed out"

    # A's reply arrives late, after the timeout.
    socket.release!
    socket.push_read("A-REPLY#{EOT}")

    error = assert_raises(RpmsRpc::Client::ConnectionError) do
      client.instance_variable_set(:@timeout, 1)
      client.call_rpc("B RPC")
    end
    refute_match(/A-REPLY/, error.message)
    assert socket.closed?, "a timed-out read must close the desynchronized socket"
  end

  # -- B: a public receive method must not reach the socket unlocked --------

  # Client#read_until_eot (and CIA's public read_response) reached the socket
  # WITHOUT taking the wire lock: whoever reads next gets whatever the socket
  # has, so a public read issued while another caller was between its send and
  # its read consumed that caller's reply.
  def test_a_public_read_cannot_steal_an_in_flight_reply
    replies = Queue.new
    write_gate = Queue.new
    a_wrote = Queue.new
    socket = RecordingSocket.new
    socket.define_singleton_method(:write) do |str|
      a_wrote << :wrote
      write_gate.pop # park A INSIDE its wire operation, reply not yet read
      str.bytesize
    end
    socket.define_singleton_method(:recv) { |_n| replies.pop }

    client = cia_client(socket)

    a_reply = nil
    a = Thread.new { a_reply = client.call_rpc_raw("CIANBRPC GETVAR", "DUZ") }
    a_wrote.pop

    b_reply = nil
    b = Thread.new { b_reply = client.read_until_eot }
    sleep 0.1 # unlocked, B is now parked inside recv; locked, B waits for A

    replies << "A-REPLY#{EOD}"
    write_gate << :go
    replies << "B-REPLY#{EOD}"
    [ a, b ].each(&:join)

    assert_includes a_reply.to_s, "A-REPLY",
      "an unlocked public read consumed another caller's in-flight reply"
    assert_includes b_reply.to_s, "B-REPLY"
  end

  # -- B: post-timeout recovery must not touch a connection it no longer owns

  # A's CIA call times out; the socket is torn down INSIDE the lock. The old
  # shape then ran a second cleanup in a rescue AFTER the lock was released —
  # by which time the socket and session state can belong to another caller
  # that has already reconnected and re-authenticated.
  def test_timeout_recovery_does_not_reset_a_connection_it_no_longer_owns
    socket = RecordingSocket.new
    client = cia_client(socket)
    client.instance_variable_set(:@timeout, 0) # the read times out immediately

    lock_released = Queue.new
    resume = Queue.new
    original = client.method(:wire_operation)
    client.define_singleton_method(:wire_operation) do |**kw, &blk|
      original.call(**kw, &blk)
    rescue RpmsRpc::Client::TimeoutError
      lock_released << :released
      resume.pop
      raise
    end

    err = nil
    a = Thread.new do
      client.call_rpc_raw("CIANBRPC GETVAR", "DUZ")
    rescue StandardError => e
      err = e
    end
    lock_released.pop

    # B reconnects and re-authenticates in the window between A's lock
    # release and whatever A still runs on its timeout path.
    fresh = RecordingSocket.new
    client.synchronize_wire do
      client.instance_variable_set(:@socket, fresh)
      client.instance_variable_set(:@connected, true)
      client.instance_variable_set(:@authenticated, true)
      client.instance_variable_set(:@duz, "302")
      client.instance_variable_set(:@session_uid, "9")
    end

    resume << :go
    a.join

    assert_kind_of RpmsRpc::Client::RpcTimeoutError, err
    refute fresh.closed?, "A's timeout recovery closed a socket it no longer owns"
    assert client.connected?, "A's timeout recovery disconnected B's live connection"
    assert_equal "302", client.duz, "A's timeout recovery erased B's authenticated identity"
    assert_equal "9", client.session_uid
  end

  # -- B: create_context commits its binding under the lock (XWB) -----------

  # Same class as committing @duz after the lock: A binds its option on the
  # wire, releases, B binds another; A then writes ITS option into
  # @current_context — client state and broker bind now disagree, and a later
  # with_context sees a match and skips the rebind.
  def test_create_context_commits_its_binding_under_the_lock
    socket = RecordingSocket.new([ "1#{EOT}", "1#{EOT}" ])
    client = RpmsRpc::XwbClient.new
    client.instance_variable_set(:@socket, socket)
    client.instance_variable_set(:@connected, true)
    client.instance_variable_set(:@authenticated, true)
    client.instance_variable_set(:@timeout, 1)
    client.define_singleton_method(:xwb_encrypt) { |s| s } # readable frames

    parked = Queue.new
    resume = Queue.new
    original = client.method(:wire_operation)
    client.define_singleton_method(:wire_operation) do |**kw, &blk|
      r = original.call(**kw, &blk)
      if Thread.current[:park_after_wire]
        parked << :parked
        resume.pop
      end
      r
    end

    a = Thread.new do
      Thread.current[:park_after_wire] = true
      client.create_context("OR CPRS GUI CHART")
    end
    parked.pop
    b = Thread.new { client.create_context("AGGRPC") }
    sleep 0.1
    resume << :go
    [ a, b ].each(&:join)

    last_bound_on_wire = socket.writes.select { |w| w.include?("XWB CREATE CONTEXT") }
                               .last[/OR CPRS GUI CHART|AGGRPC/]
    assert_equal last_bound_on_wire, client.current_context,
      "the client's context diverged from the broker's last CREATE CONTEXT — " \
      "a later with_context will see a match and skip the rebind"
  end

  # -- B: CIA create_context must wait for a held context scope -------------

  # CIA's context bind is pure client state (the CTX field on every later
  # frame), so an unlocked create_context re-binds the context INSIDE another
  # thread's with_context scope, and the scoped RPC's frame carries the
  # intruder's option.
  def test_cia_create_context_waits_for_the_wire_lock
    socket = RecordingSocket.new([ "OK#{EOD}" ])
    client = cia_client(socket)
    client.instance_variable_set(:@authenticated, true)
    client.create_context("BASE") # a declared starting context to restore to

    in_scope = Queue.new
    scoped = Thread.new do
      client.with_context("AGGRPC") do
        in_scope << :in
        sleep 0.15 # the window the intruder lands in
        client.call_rpc_raw("CIANBRPC GETVAR", "DUZ")
      end
    end
    in_scope.pop
    intruder = Thread.new { client.create_context("SOMETHING ELSE") }
    [ scoped, intruder ].each(&:join)

    frame = socket.writes.find { |w| w.include?("CIANBRPC GETVAR") }
    ctx_field = client.send(:pk, "CTX") + client.send(:pk, "") + client.send(:pk, "AGGRPC")
    assert_includes frame, ctx_field,
      "another thread's create_context re-bound the context inside a held scope, " \
      "so the scoped RPC ran under the wrong option"
  end

  # -- B: a mid-write connection drop must be typed and torn down -----------

  # CIA writes its frame straight to the socket. A mid-write EPIPE/ECONNRESET
  # propagated RAW and left @connected true — the next caller started an
  # exchange on a client whose connection state was a lie.
  def test_a_mid_write_drop_raises_typed_and_tears_the_connection_down
    { Errno::EPIPE => "EPIPE", IOError => "stream closed" }.each do |error_class, label|
      socket = RecordingSocket.new
      socket.define_singleton_method(:write) { |*| raise error_class, label }
      client = cia_client(socket)

      err = assert_raises(RpmsRpc::Client::ConnectionError,
        "a mid-write #{error_class} must surface as a typed ConnectionError") do
        client.call_rpc_raw("CIANBRPC GETVAR", "DUZ")
      end
      refute_kind_of RpmsRpc::Client::TimeoutError, err
      refute client.connected?, "#{error_class}: @connected still true over a dead socket"
      assert socket.closed?, "#{error_class}: the dropped socket was left open"
    end
  end

  # -- B: IO::TimeoutError is a TIMEOUT, and gets the timeout teardown ------

  # Converting IO::TimeoutError to ConnectionError skipped the timeout
  # cleanup entirely: the desynchronized socket stayed open and reusable,
  # and the next caller could read the abandoned reply as its own.
  def test_an_io_timeout_gets_the_same_teardown_as_a_deadline_timeout
    socket = RecordingSocket.new
    socket.define_singleton_method(:recv) { |*| raise IO::TimeoutError, "read timed out" }
    client = cia_client(socket)

    assert_raises(RpmsRpc::Client::TimeoutError,
      "an IO::TimeoutError is a timeout — it must not be retyped as generic connection loss") do
      client.call_rpc_raw("CIANBRPC GETVAR", "DUZ")
    end
    refute client.connected?
    assert socket.closed?, "an IO::TimeoutError left a desynchronized socket reusable"
  end

  # -- M: the sign-on setup cache crosses clients and survives reconnects --

  # XUS SIGNON SETUP establishes the partition each AV CODE is validated in.
  # A module-level cache meant the SECOND sign-on skipped it entirely — on a
  # different client, or on the same client after a reconnect.
  def test_every_sign_on_runs_xus_signon_setup
    RpmsRpc::Authentication.clear_cache!
    seed = lambda do
      RpmsRpc.mock! do |m|
        m.seed_scalar(:signon_setup, "", "OK")
        m.seed_user("301", credentials: "AAA;AAA1", name: "ALPHA,ANA", role: :provider)
      end
    end

    seed.call
    RpmsRpc::Authentication.authenticate(access_code: "AAA", verify_code: "AAA1")

    # A replaced client is a new broker session and must set up its own.
    seed.call
    RpmsRpc::Authentication.authenticate(access_code: "AAA", verify_code: "AAA1")

    setups = RpmsRpc.client.received_calls.count { |c| c[:rpc] == "XUS SIGNON SETUP" }
    assert_equal 1, setups, "the replacement client's sign-on skipped XUS SIGNON SETUP"
  ensure
    RpmsRpc::Authentication.clear_cache!
    RpmsRpc.reset!
  end

  # -- M: context scopes must be atomic across bind / call / restore -------

  # with_context binds an option, runs the block, and restores. Another thread
  # binding in between means the block — or a capability probe inside it — runs
  # under the wrong option, and the broker answers a truthful "not runnable
  # here" that is indistinguishable from "not installed".
  def test_a_context_scope_is_not_interleaved_by_another_binder
    mock = RpmsRpc.mock!
    mock.create_context("BASE")
    mock.seed_scalar(:signon_setup, "", "OK")

    scoped = Thread.new do
      mock.with_context("AGGRPC") do
        sleep 0.1 # the window another binder can land in
        mock.call_rpc("XUS SIGNON SETUP")
      end
    end
    sleep 0.02
    intruder = Thread.new { mock.with_context("SOMETHING ELSE") { sleep 0.15 } }
    [ scoped, intruder ].each(&:join)

    # MockClient records the context bound at the moment of each call.
    call = mock.received_calls.find { |c| c[:rpc] == "XUS SIGNON SETUP" }
    assert_equal "AGGRPC", call[:context],
      "the scoped call ran under another thread's context, so the broker gates it " \
      "against the wrong option"
  ensure
    RpmsRpc.reset!
  end

  # -- M: disconnect must not inject #BYE# into someone else's RPC ---------

  def test_disconnect_waits_for_an_in_flight_rpc
    socket = RecordingSocket.new([ "SLOW#{EOT}" ])
    client = RpmsRpc::XwbClient.new
    client.instance_variable_set(:@socket, socket)
    client.instance_variable_set(:@connected, true)
    client.instance_variable_set(:@timeout, 1)

    timeline = Queue.new
    in_flight = Queue.new
    client.define_singleton_method(:read_response) do
      in_flight << :sending
      timeline << :read_start
      sleep 0.15
      timeline << :read_done
      "OK#{EOT}"
    end
    socket.define_singleton_method(:write) do |str|
      timeline << :bye_written if str.to_s.include?("#BYE#")
      super(str)
    end

    rpc = Thread.new { client.call_rpc("SLOW RPC") }
    in_flight.pop
    closer = Thread.new { client.disconnect }
    [ rpc, closer ].each(&:join)

    events = []
    events << timeline.pop until timeline.empty?
    assert_equal %i[read_start read_done bye_written], events,
      "#BYE# was injected into the middle of an in-flight RPC"
  end
end
