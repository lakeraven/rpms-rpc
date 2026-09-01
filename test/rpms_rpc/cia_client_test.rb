# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/cia_client"

class RpmsRpc::CiaClientTest < Minitest::Test
  Client = RpmsRpc::CiaClient
  EOD = RpmsRpc::Client::EOD

  # Minimal fake socket: canned recv chunks, records writes. An exhausted read
  # queue returns "" — i.e. the peer closed the connection.
  class FakeSocket
    attr_reader :writes

    def initialize(reads)
      @reads = reads.dup
      @writes = []
    end

    def recv(_n) = @reads.empty? ? "" : @reads.shift
    def write(str) = (@writes << str) && str.bytesize
    def flush; end
    def close = @closed = true
    def closed? = !!@closed
    def setsockopt(*); end
  end

  def connected_client(reads)
    c = Client.new
    c.instance_variable_set(:@socket, FakeSocket.new(reads))
    c.instance_variable_set(:@connected, true)
    c.instance_variable_set(:@timeout, 5)
    c.instance_variable_set(:@seq, 0)
    c
  end

  def test_inherits_from_client
    assert Client < RpmsRpc::Client
  end

  def test_default_port_is_9100
    assert_equal 9100, Client.new.port
  end

  # Fix (#172 Copilot): call_rpc_raw must return the UNMODIFIED broker response —
  # it is no longer an alias of call_rpc, which strips non-printables.
  def test_call_rpc_raw_returns_unmodified_response
    raw = "ab\x01\x1fcd" # embedded non-printable bytes (\x1f != EOD \x1e)
    c = connected_client([ raw + EOD ])
    assert_equal raw, c.call_rpc_raw("CIANBRPC CANRUN", "XUS INTRO MSG")
  end

  def test_call_rpc_strips_non_printables
    c = connected_client([ "ab\x01\x1fcd" + EOD ])
    assert_equal "ab  cd", c.call_rpc("CIANBRPC CANRUN", "XUS INTRO MSG")
  end

  # Fix (#172 Copilot): a peer-closed read (empty recv) must clear @connected,
  # not leave the client reporting connected against a dead socket.
  def test_empty_recv_clears_connected_and_raises
    c = connected_client([]) # recv → "" immediately
    assert_raises(RpmsRpc::Client::ConnectionError) { c.call_rpc_raw("X", "Y") }
    refute c.connected?, "peer-closed read must clear @connected"
  end

  # Fix (#178 Copilot): a failed connect handshake (empty reply, timeout, write
  # error) must close the socket and reset state — not leak the open socket
  # behind a retried connect.
  def test_failed_connect_handshake_closes_socket_and_resets_state
    c = Client.new
    socket = FakeSocket.new([ EOD ]) # broker answers connect with an empty reply
    c.define_singleton_method(:open_socket) { |_h, _p| @socket = socket }
    assert_raises(RpmsRpc::Client::ConnectionError) { c.connect("localhost", 9100) }
    assert socket.closed?, "failed handshake must close the socket, not leak it"
    refute c.connected?
    assert_nil c.instance_variable_get(:@socket)
  end

  # CIA length prefix: header byte = (num_length_bytes << 4) | (len % 16),
  # then big-endian length-quotient bytes, then the value.
  def test_pk_frames_short_value
    # "AB" len 2: quotient 0 → no length bytes, header = (0<<4)|2 = \x02
    assert_equal "\x02AB".b, Client.new.send(:pk, "AB")
  end

  def test_pk_frames_value_over_16_bytes
    v = "x" * 17 # len 17: n = 1, q = 1 → one length byte \x01, header = (1<<4)|1 = \x11
    assert_equal ("\x11\x01" + v).b, Client.new.send(:pk, v)
  end

  # -- CIANBRPC AUTH reply parsing (DUZ + session UID) ------------------------
  #
  # AUTH^CIANBRPC reply: <seq echo><\x00 ack>, then CR+LF-separated lines —
  # line 1 status ("0" = success), line 2 params "UID^netname^sitename",
  # lines 3+ greeting. DUZ is NOT in the reply; it is saved into the session
  # environment and fetched with CIANBRPC GETVAR ("DUZ=n").

  AUTH_REPLY = "1\x000\r\n7^DEMO.EXAMPLE.ORG^DEMO CLINIC\r\n\r\n" \
               "Good evening USER,DEMO\r\n     You last signed on today at 08:15\r\n"
  GETVAR_REPLY = "2\x00DUZ=63\r\n"

  def test_authenticate_populates_duz_via_session_env
    c = connected_client([ AUTH_REPLY + EOD, GETVAR_REPLY + EOD ])
    result = c.authenticate("SYN123", "SYN123!!")
    assert result[:success]
    assert_equal "USER,DEMO", result[:user]
    assert_equal 63, result[:duz]
    assert_equal "63", c.duz
  end

  def test_authenticate_captures_session_uid_and_uses_it_on_later_calls
    c = connected_client([ AUTH_REPLY + EOD, GETVAR_REPLY + EOD, "3\x00ok\r\n" + EOD ])
    c.authenticate("SYN123", "SYN123!!")
    assert_equal "7", c.session_uid
    c.call_rpc("CIANBRPC CANRUN", "XUS INTRO MSG")
    # UID field of the post-auth frame carries the broker-assigned session UID
    assert_includes c.instance_variable_get(:@socket).writes.last, "\x03UID\x00\x017".b
  end

  def test_authenticate_duz_nil_when_session_env_lacks_it
    c = connected_client([ AUTH_REPLY + EOD, "2\x00\r\n" + EOD ])
    result = c.authenticate("SYN123", "SYN123!!")
    assert result[:success]
    assert_nil result[:duz]
    assert_nil c.duz
  end

  # -- mid-call read timeout --------------------------------------------------
  #
  # A {CIA} reply has no length framing (EOD terminator only), so a reply
  # abandoned mid-read cannot be resynchronized. A single hung RPC must
  # surface as RpcTimeoutError with the socket closed — a defined state —
  # not poison later exchanges with the stale reply.

  # Fake socket for a broker that stalls mid-reply: first chunk arrives
  # without the EOD terminator, then reads block past the client deadline.
  class StallingSocket
    attr_reader :writes

    def initialize
      @writes = []
      @reads = 0
      @closed = false
    end

    def recv(_n)
      @reads += 1
      return "PARTIAL " if @reads == 1

      sleep 0.15 # stall past the client's deadline
      "STILL NO TERMINATOR "
    end

    def write(str) = (@writes << str) && str.bytesize
    def flush; end
    def close = @closed = true
    def closed? = @closed
    def setsockopt(*); end
  end

  def stalled_client
    c = Client.new
    c.instance_variable_set(:@socket, StallingSocket.new)
    c.instance_variable_set(:@connected, true)
    c.instance_variable_set(:@timeout, 0.1)
    c.instance_variable_set(:@seq, 0)
    c
  end

  def test_hung_rpc_raises_rpc_timeout_error
    c = stalled_client
    err = assert_raises(RpmsRpc::Client::RpcTimeoutError) { c.call_rpc_raw("BEHOPTCX PTINFO") }
    assert_match(/timed out/, err.message)
    assert_match(/reconnect and re-authenticate/, err.message)
  end

  def test_rpc_timeout_error_is_distinct_but_rescuable_as_connection_error
    assert RpmsRpc::Client::RpcTimeoutError < RpmsRpc::Client::TimeoutError
    assert RpmsRpc::Client::RpcTimeoutError < RpmsRpc::Client::ConnectionError
  end

  def test_hung_rpc_leaves_client_in_defined_disconnected_state
    c = stalled_client
    socket = c.instance_variable_get(:@socket)
    assert_raises(RpmsRpc::Client::RpcTimeoutError) { c.call_rpc_raw("BEHOPTCX PTINFO") }
    refute c.connected?, "timed-out client must not report connected"
    refute c.authenticated?
    assert socket.closed?, "abandoned socket must be closed (stream cannot resync)"
    assert_nil c.session_uid
    # Later calls fail fast with the normal not-connected error, not a hang
    # or a stale-reply misread.
    err = assert_raises(RpmsRpc::Client::ConnectionError) { c.call_rpc("XWB IM HERE") }
    refute_kind_of RpmsRpc::Client::RpcTimeoutError, err
  end
end
