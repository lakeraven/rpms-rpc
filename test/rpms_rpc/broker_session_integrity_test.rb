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
