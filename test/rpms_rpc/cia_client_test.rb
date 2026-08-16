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
    def close; end
    def closed? = false
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
end
