# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/cia_client"
require "rpms_rpc/api/authentication"
require "rpms_rpc/mock_client"

# The broker protocol is a bare request/response stream with no per-message
# correlation id: whoever reads next gets whatever the socket has. `RpmsRpc.client`
# is process-global, so "two threads sharing a client" means "two clinicians
# signing on at once" — and a crossed reply hands one of them the other's DUZ,
# role and security keys on the surface that decides who may read a
# behavioral-health chart.
class RpmsRpc::BrokerConcurrencyTest < Minitest::Test
  EOD = RpmsRpc::Client::EOD

  # A fake socket that behaves like the real peer: replies are queued in the
  # order the requests arrived, and `recv` hands back the OLDEST pending reply
  # regardless of which thread asks for it. `write_pause` parks the first
  # writer between its send and its read, which is exactly the window a real
  # network hands you.
  class FifoFakeSocket
    def initialize(replies, write_pause: 0.0)
      @replies = Queue.new
      @answers = replies
      @write_pause = write_pause
      @paused = false
      @mutex = Mutex.new
    end

    def write(str)
      key = @answers.keys.find { |k| str.include?(k) }
      @replies << (@answers[key] || "")
      pause_once
      str.bytesize
    end

    def recv(_n) = @replies.pop
    def flush; end
    def close = @closed = true
    def closed? = !!@closed
    def setsockopt(*); end

    private

    # Only the first writer parks; the second must be free to run to completion
    # inside that window (or to block on the wire lock, which is the point).
    def pause_once
      should_pause = @mutex.synchronize { @paused ? false : (@paused = true) }
      sleep @write_pause if should_pause && @write_pause.positive?
    end
  end

  def connected_client(socket)
    c = RpmsRpc::CiaClient.new
    c.instance_variable_set(:@socket, socket)
    c.instance_variable_set(:@connected, true)
    c.instance_variable_set(:@timeout, 5)
    c.instance_variable_set(:@seq, 0)
    c
  end

  def test_concurrent_rpcs_on_one_client_do_not_exchange_replies
    socket = FifoFakeSocket.new(
      { "CLINICIAN-A" => "DUZ=301#{EOD}", "CLINICIAN-B" => "DUZ=302#{EOD}" },
      write_pause: 0.2
    )
    client = connected_client(socket)

    replies = {}
    threads = [
      Thread.new { replies[:a] = client.call_rpc_raw("CIANBRPC GETVAR", "CLINICIAN-A") },
      Thread.new { sleep 0.05; replies[:b] = client.call_rpc_raw("CIANBRPC GETVAR", "CLINICIAN-B") }
    ]
    threads.each(&:join)

    assert_includes replies[:a], "DUZ=301",
      "thread A read thread B's reply — two sign-ons just swapped identities"
    assert_includes replies[:b], "DUZ=302",
      "thread B read thread A's reply — two sign-ons just swapped identities"
  end

  # The multi-RPC sign-on sequence (XUS SIGNON SETUP -> XUS AV CODE ->
  # XUS GET USER INFO -> ORWU USERKEYS) must not interleave with another
  # sign-on either: a per-call lock alone still lets B's AV CODE land between
  # A's AV CODE and A's user lookup, so A gets B's name and keys.
  def test_signon_sequence_is_serialized_against_a_concurrent_signon
    RpmsRpc::Authentication.clear_cache!
    RpmsRpc.mock! do |m|
      m.seed_scalar(:signon_setup, "", "OK")
      m.seed_user("301", credentials: "AAA;AAA1", name: "ALPHA,ANA", role: :provider)
    end

    order = Queue.new
    RpmsRpc.client.define_singleton_method(:call_rpc) do |rpc_name, *params|
      order << [ Thread.current[:lane], rpc_name ]
      sleep 0.02
      super(rpc_name, *params)
    end

    threads = %i[a b].map do |lane|
      Thread.new do
        Thread.current[:lane] = lane
        RpmsRpc::Authentication.authenticate(access_code: "AAA", verify_code: "AAA1")
      end
    end
    threads.each(&:join)

    lanes = []
    lanes << order.pop until order.empty?
    runs = lanes.chunk_while { |a, b| a.first == b.first }.to_a

    assert_equal 2, runs.length,
      "a second sign-on interleaved into the first — each lane must be one unbroken run: #{lanes.inspect}"
  ensure
    RpmsRpc::Authentication.clear_cache!
    RpmsRpc.reset!
  end
end
