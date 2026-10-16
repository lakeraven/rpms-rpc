# frozen_string_literal: true

require "socket"
require_relative "live_helper"
require "rpms_rpc/api/problem"

# The two transport failures a host tells apart from an RPC error (#357):
# a reply that does not come in time raises Client::RpcTimeoutError
# (504-like), and a connection that goes away raises Client::ConnectionError
# (502/503-like). Both are provoked here on a real broker session; neither
# needs a fake server.
#
# Each test signs on with a client of its own, so the harness's session is
# not the one that fails.
class ConnectionFailureLiveTest < LiveSpec::Test
  # ORQQPL PROBLEM LEX SEARCH for "fracture" took 5.7-5.9 s on each of three
  # runs against bcer-9.0-20261012-e7923a4-ydb on loopback (2026-10-16), well
  # past the one-second client timeout below. The client's timeout is whole
  # seconds (Client#initialize calls to_i), so one second is the shortest.
  SLOW_SEARCH = "fracture"
  SHORT_TIMEOUT = 1

  def test_a_reply_slower_than_the_client_timeout_raises_rpc_timeout
    c = signed_on_client(ENV.fetch("BROKER_HOST"), Integer(ENV.fetch("BROKER_PORT")), timeout: SHORT_TIMEOUT)
    RpmsRpc.configure { |cfg| cfg.client = c }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    err = assert_raises(RpmsRpc::Client::RpcTimeoutError) { RpmsRpc::Problem.lex_search(SLOW_SEARCH) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_kind_of RpmsRpc::Client::ConnectionError, err
    assert_operator elapsed, :<, SHORT_TIMEOUT + 2, "the timeout fired after #{elapsed.round(2)} s, not at the client's #{SHORT_TIMEOUT} s"
    refute c.connected?, "the client kept the desynchronized socket after the timeout"
    puts "\n#{persona}: lex_search(#{SLOW_SEARCH.inspect}) with a #{SHORT_TIMEOUT} s timeout raised #{err.class.name.split('::').last} after #{elapsed.round(2)} s"
  ensure
    c&.disconnect
  end

  # The session runs through a TCP relay this test owns. After one RPC answers,
  # the relay drops both sides, as a lost tunnel or a dead broker would, and the
  # next RPC raises ConnectionError instead of answering empty.
  def test_a_connection_lost_mid_session_raises_connection_error
    relay = Relay.new(ENV.fetch("BROKER_HOST"), Integer(ENV.fetch("BROKER_PORT")))
    c = signed_on_client("127.0.0.1", relay.port, timeout: 30)
    RpmsRpc.configure { |cfg| cfg.client = c }
    refute_empty RpmsRpc::Problem.lex_search("diabetes"), "the session through the relay did not answer before the cut"

    relay.cut!
    err = assert_raises(RpmsRpc::Client::ConnectionError) { RpmsRpc::Problem.lex_search("diabetes") }

    assert_instance_of RpmsRpc::Client::ConnectionError, err
    assert_match(/Connection (lost|closed)/, err.message)
    refute c.connected?, "the client still reports a connection after it was lost"
    puts "\n#{persona}: after the relay cut, lex_search raised ConnectionError (#{err.message})"
  ensure
    c&.disconnect
    relay&.close
  end

  private

  def signed_on_client(host, port, timeout:)
    c = RpmsRpc::CiaClient.new(host: host, port: port, timeout: timeout)
    c.connect
    c.authenticate(ENV.fetch("RPMS_ACCESS"), ENV.fetch("RPMS_VERIFY"))
    c
  end

  # One client connection, copied byte for byte to the broker and back.
  class Relay
    attr_reader :port

    def initialize(host, port)
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @sockets = []
      @threads = [ Thread.new { accept(host, port) } ]
    end

    # Drop both sides of the relayed connection.
    def cut!
      @sockets.each { |s| s.close unless s.closed? }
    end

    def close
      cut!
      @server.close unless @server.closed?
      @threads.each { |t| t.join(2) }
    end

    private

    def accept(host, port)
      down = @server.accept
      up = TCPSocket.new(host, port)
      @sockets.push(down, up)
      @threads << Thread.new { pump(down, up) } << Thread.new { pump(up, down) }
    rescue IOError, SystemCallError
      nil # closed before a client connected
    end

    def pump(from, to)
      IO.copy_stream(from, to)
    rescue IOError, SystemCallError
      nil # the cut closed a side mid-copy
    end
  end
end
