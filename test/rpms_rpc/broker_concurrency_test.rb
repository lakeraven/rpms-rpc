# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/cia_client"
require "rpms_rpc/version"
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

  # A broker-faithful fake for the FULL sign-on contract: an AUTH binds the
  # session identity (last AUTH wins — exactly the real broker's behaviour),
  # a CIAVCXUS VIMINFO answers with whatever identity the session holds
  # RIGHT NOW,
  # and replies are served strictly FIFO to whoever reads next.
  class SignonBrokerSocket
    attr_reader :frames

    def initialize
      @replies = Queue.new
      @frames = []
      @auths = 0
      @session = 0 # which sign-on's identity the broker session holds NOW
      @mutex = Mutex.new
    end

    def write(str)
      @mutex.synchronize do
        @frames << str.dup
        # Fix (#251, found verifying the Copilot framing finding): every reply
        # carries the frame's own sequence echo and the \x00 DATA flag, as a
        # real broker's does — the client consumes both before it
        # reads a field, and a fake that omits them lets a client that frames
        # replies by hand pass. Sequence byte: {CIA}<EOD><seq><action>...
        ack = "#{str[/\A\{CIA\}#{Regexp.escape(EOD)}(.)/, 1]}\x00"
        if str.include?("CIANBRPC AUTH")
          @auths += 1
          @session = @auths
          @replies << "#{ack}0\r\n7#{@auths}^NET^SITE\r\nSigned on as USER#{@auths}\r\n#{EOD}"
        elsif str.include?("LANE-")
          @replies << "#{ack}#{str[/LANE-[AB]/]}-OK#{EOD}"
        else # CIAVCXUS VIMINFO — piece 1 is the DUZ of the CURRENT session identity
          @replies << "#{ack}#{300 + @session}^USER#{@session}^1800;1800;60^0^0#{EOD}"
        end
      end
      sleep 0.01 # widen the send-then-read window a broken client would leak in
      str.bytesize
    end

    def recv(_n) = @replies.pop
    def flush; end
    def close = @closed = true
    def closed? = !!@closed
    def setsockopt(*); end
  end

  # The contract lakeraven-ehr's SSO bridge (#486) rides: two clinicians
  # driving sign-on + RPC through ONE shared client must never interleave
  # frames inside a sign-on sequence, never consume each other's replies,
  # and never reset each other's socket. Sign-on binds the session identity
  # with AUTH and reads it back with CIAVCXUS VIMINFO — if anything lands
  # between the two, the reader is minted with the OTHER clinician's DUZ.
  def test_two_threads_signing_on_and_calling_never_interleave_or_cross_reset
    socket = SignonBrokerSocket.new
    client = connected_client(socket)

    threads = %i[a b].map do |lane|
      Thread.new do
        client.authenticate("USER#{lane}", "PW#{lane}")
        client.call_rpc_raw("CIANBRPC GETVAR", "LANE-#{lane.to_s.upcase}")
      end
    end
    threads.each(&:join)

    socket_frames = socket.frames.map do |f|
      if f.include?("CIANBRPC AUTH") then :auth
      elsif f.include?("LANE-") then :lane_rpc
      else :duz_read
      end
    end

    # 1. Every AUTH is immediately followed by ITS DUZ read — no frame from
    #    the other sign-on lands inside the pair.
    socket_frames.each_with_index do |kind, i|
      next unless kind == :auth

      assert_equal :duz_read, socket_frames[i + 1],
        "a frame interleaved into a sign-on sequence: #{socket_frames.inspect}"
    end

    refute socket.closed?, "a concurrent caller reset the shared socket mid-run"
    assert client.connected?
  end

  # Same run, asserting the identities: each thread's sign-on result must
  # carry the DUZ of the AUTH *it* performed (the greeting names which),
  # and each thread's RPC reply must be its own.
  def test_two_threads_signing_on_each_get_their_own_identity_and_replies
    socket = SignonBrokerSocket.new
    client = connected_client(socket)

    # Fix (#251 Fable gate, F2): contend the window the OUTER sign-on lock
    # exists to close — between AUTH's exchange releasing the wire and the
    # identity read re-acquiring it. SignonBrokerSocket's own `sleep` sits
    # inside exchange's per-frame lock, so it can never widen that gap: without
    # this hook the outer `synchronize_wire` can be deleted outright and these
    # assertions still pass, which makes them evidence for nothing.
    client.define_singleton_method(:signon_duz) do
      sleep 0.05 # let the other lane's AUTH land here, if anything lets it
      super()
    end

    results = {}
    mutex = Mutex.new
    threads = %i[a b].map do |lane|
      Thread.new do
        signon = client.authenticate("USER#{lane}", "PW#{lane}")
        rpc_reply = client.call_rpc_raw("CIANBRPC GETVAR", "LANE-#{lane.to_s.upcase}")
        mutex.synchronize { results[lane] = { signon: signon, rpc_reply: rpc_reply } }
      end
    end
    threads.each(&:join)

    duzes = %i[a b].map do |lane|
      signon = results[lane][:signon]
      auth_index = signon[:greeting][/USER(\d)/, 1].to_i
      assert_equal 300 + auth_index, signon[:duz],
        "lane #{lane} read back a DUZ bound by the OTHER lane's AUTH — " \
        "the sign-on sequence interleaved: #{signon.inspect}"
      assert_includes results[lane][:rpc_reply], "LANE-#{lane.to_s.upcase}-OK",
        "lane #{lane} consumed the other lane's RPC reply"
      signon[:duz]
    end

    assert_equal [ 301, 302 ], duzes.sort,
      "the two sign-ons did not yield two distinct identities: #{duzes.inspect}"
  end
end
