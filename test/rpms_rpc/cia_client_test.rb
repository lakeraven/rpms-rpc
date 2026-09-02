# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/cia_client"
require "rpms_rpc/xwb_client"

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

  # call_rpc deframes (strips the 1-byte seq echo + \x00 ack the broker
  # prepends) then replaces remaining non-printables with spaces. Real wire
  # framing: "<seq>\x00<body>".
  def test_call_rpc_deframes_and_strips_non_printables
    c = connected_client([ "5\x00ab\x01\x1fcd" + EOD ])
    assert_equal "ab  cd", c.call_rpc("CIANBRPC CANRUN", "XUS INTRO MSG")
  end

  # A multi-line reply uses BARE CR (\r) delimiters on the wire (live:
  # rpms-ydb-9.0, 2026-09-02). deframe must keep the line structure — printable
  # no longer flattens \r/\n to spaces — so a DDR-style reply survives intact.
  def test_call_rpc_preserves_bare_cr_line_structure
    c = connected_client([ "6\x00[Data]\r4^ONE\r3^TWO\r" + EOD ])
    assert_equal "[Data]\n4^ONE\n3^TWO", c.call_rpc("DDR LISTER", "9000001")
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

  # Real wire framing (rpms-ydb-9.0, 2026-09-02): "<seq echo>\x00<body>" with
  # the body's lines delimited by BARE CR (\r), not CRLF. The session UID lives
  # in body line index 1 piece 0 ("7^netname^sitename") — the whole point of
  # the deframe fix is that this parses (the old \r\n/\n split missed bare CR,
  # leaving session_uid/DUZ nil).
  AUTH_REPLY = "1\x000\r7^DEMO.EXAMPLE.ORG^DEMO CLINIC\r\r" \
               "Good evening USER,DEMO\r     You last signed on today at 08:15\r"
  GETVAR_REPLY = "2\x00DUZ=63\r"

  def test_authenticate_populates_duz_via_session_env
    c = connected_client([ AUTH_REPLY + EOD, GETVAR_REPLY + EOD ])
    result = c.authenticate("SYN123", "SYN123!!")
    assert result[:success]
    assert_equal "USER,DEMO", result[:user]
    assert_equal 63, result[:duz]
    assert_equal "63", c.duz
  end

  def test_authenticate_captures_session_uid_and_uses_it_on_later_calls
    c = connected_client([ AUTH_REPLY + EOD, GETVAR_REPLY + EOD, "3\x00ok\r" + EOD ])
    c.authenticate("SYN123", "SYN123!!")
    assert_equal "7", c.session_uid
    c.call_rpc("CIANBRPC CANRUN", "XUS INTRO MSG")
    # UID field of the post-auth frame carries the broker-assigned session UID
    assert_includes c.instance_variable_get(:@socket).writes.last, "\x03UID\x00\x017".b
  end

  def test_authenticate_duz_nil_when_session_env_lacks_it
    c = connected_client([ AUTH_REPLY + EOD, "2\x00\r" + EOD ])
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

  # The {CIA} header is fixed-width: DOACTION^CIANBLIS reads exactly 8 bytes
  # ("{CIA}" + EOD + 1-byte sequence + action) and echoes the sequence byte
  # back. A counter that grows to "10" shifts the action byte out of its slot
  # and corrupts every frame from the tenth on, so the client must wrap the
  # counter to keep the sequence a single byte.
  def test_seq_stays_one_byte_across_more_than_ten_exchanges
    replies = Array.new(12) { |i| "#{(i % 9) + 1}\x00ok\r\n" + EOD }
    c = connected_client(replies)
    seqs = []
    12.times do
      c.call_rpc("XWB IM HERE")
      frame = c.instance_variable_get(:@socket).writes.last
      assert_equal "{CIA}#{EOD}", frame[0, 6], "frame must start with the fixed 6-byte prologue"
      seqs << frame[6]
      assert_equal "R", frame[7], "action byte must sit at offset 7, after a single sequence byte"
    end
    assert_equal %w[1 2 3 4 5 6 7 8 9 1 2 3], seqs
  end

  # -- strict {CIA} mock broker ----------------------------------------------
  #
  # The canned-reply FakeSocket above never PARSES what the client writes, so
  # this suite would stay green even if the client stopped speaking {CIA}
  # entirely — which is exactly how a wrong-protocol client (a pre-rename
  # CiaClient that actually spoke stock XWB [XWB]1130) got mistaken for a live
  # v0.2.0 connect regression against the real broker (rpms-ops evidence run,
  # 2026-09-01). This socket emulates DOACTION^CIANBLIS as observed on the
  # real wire (bcer-9.0-ydb, CIANBLIS on :9100):
  #
  #   C->S  {CIA}<EOD><seq byte><action byte><L()-packed fields ...><EOD>
  #   S->C  <seq echo>   then   <\x00 ack><body><EOD>   (two separate chunks)
  #
  # Connect ("C") reply body observed live: "1^1^1.1^^1". And, like the real
  # broker, it answers anything that is not a parseable {CIA} frame by CLOSING
  # the session — the client sees EOF, never an error message. (^ZBLOG then
  # shows only a clean connect/disconnect pair, no SERVETRAP.)
  class StrictCiaBrokerSocket
    CONNECT_BODY = "1^1^1.1^^1"

    attr_reader :frames

    # rpc_bodies: reply bodies (without seq echo / ack / EOD) for successive
    # "R"-action frames, in order.
    def initialize(rpc_bodies = [])
      @rpc_bodies = rpc_bodies.dup
      @frames = [] # parsed frames: { seq:, action:, fields: }
      @pending = []
      @closed_by_broker = false
      @closed = false
    end

    def write(str)
      return str.bytesize if @closed_by_broker

      frame = parse_frame(str.b)
      if frame.nil? # not a {CIA} frame — DOACTION ends the session
        @closed_by_broker = true
        @pending.clear
        return str.bytesize
      end
      @frames << frame
      body = frame[:action] == "C" ? CONNECT_BODY : @rpc_bodies.shift.to_s
      @pending << frame[:seq] # the real broker delivers the seq echo ...
      @pending << "\x00" + body + EOD # ... and the ack+body as separate chunks
      str.bytesize
    end

    def recv(_n)
      return "" if @closed_by_broker || @pending.empty?

      @pending.shift
    end

    def flush; end
    def close = @closed = true
    def closed? = !!@closed
    def setsockopt(*); end

    private

    # Parse one frame the way DOACTION^CIANBLIS reads it: exactly 8 header
    # bytes ("{CIA}" + EOD + seq + action), then L()-packed fields that must
    # land exactly on the trailing EOD. Returns nil (→ session close) on
    # anything malformed.
    def parse_frame(bytes)
      return nil unless bytes.bytesize >= 9 && bytes[0, 6] == "{CIA}#{EOD}".b && bytes[-1] == EOD

      fields = []
      i = 8
      while i < bytes.bytesize - 1
        hdr = bytes.getbyte(i)
        nlen = hdr >> 4
        n = hdr & 0xf
        i += 1
        q = 0
        nlen.times do
          q = (q << 8) | bytes.getbyte(i).to_i
          i += 1
        end
        len = (q << 4) | n
        val = bytes.byteslice(i, len)
        return nil if val.nil? || val.bytesize < len

        fields << val
        i += len
      end
      return nil unless i == bytes.bytesize - 1 # fields must end at the EOD

      { seq: bytes[6], action: bytes[7], fields: fields }
    end
  end

  def client_on_strict_broker(rpc_bodies = [])
    c = Client.new
    socket = StrictCiaBrokerSocket.new(rpc_bodies)
    c.define_singleton_method(:open_socket) { |_h, _p| @socket = socket }
    c.instance_variable_set(:@timeout, 5)
    [ c, socket ]
  end

  def test_connect_survives_strict_broker_frame_parsing
    c, broker = client_on_strict_broker
    assert c.connect("localhost", 9100)
    assert c.connected?
    frame = broker.frames.first
    assert_equal "1", frame[:seq]
    assert_equal "C", frame[:action]
    assert_equal [ "VER", "", "2.0", "LP", "", "9100", "UCI", "", "VEH,EXTERNAL" ], frame[:fields]
  end

  def test_full_signon_round_trip_against_strict_broker
    c, broker = client_on_strict_broker([
      "0\r7^DEMO.EXAMPLE.ORG^DEMO CLINIC\r\rGood evening USER,DEMO\r", # CIANBRPC AUTH
      "DUZ=63\r",                                                      # CIANBRPC GETVAR
      "ok\r"                                                           # the RPC proper
    ])
    c.connect("localhost", 9100)
    result = c.authenticate("SYN123", "SYN123!!")
    assert result[:success]
    assert_equal 63, result[:duz]
    assert_equal "7", c.session_uid
    # deframed: seq echo "4" + \x00 ack stripped, trailing CR dropped
    assert_equal "ok", c.call_rpc("XWB IM HERE")
    # every frame the broker saw parsed as {CIA}, with one-byte cycling seqs
    assert_equal %w[1 2 3 4], broker.frames.map { |f| f[:seq] }
    assert_equal %w[C R R R], broker.frames.map { |f| f[:action] }
    assert_equal "7", broker.frames.last[:fields][2], "post-auth UID field carries the session UID"
  end

  # -- list (subscripted) params on the wire ---------------------------------
  #
  # DOACTION^CIANBLIS reads each field as a NAME/SUBSCRIPT/VALUE triple of
  # L()-packed values; a numeric NAME with a non-empty SUBSCRIPT builds the
  # list param P<n>(<SUBSCRIPT>)=<VALUE> — and the subscript text is spliced
  # RAW into the M reference ('RT=RT_"("_SB_")"' / 'S @RT=VL', CIANBLIS.m
  # DOACTION lines 128-134), so string subscripts must cross the wire in
  # M-quoted form ("NAME") while numeric subscripts stay bare. This is what
  # VAFC VOA ADD PATIENT (PARAM list, ADD^VAFCPTAD) and the DDR FileMan
  # family (DDR/DDRROOT/DDRIENS lists) require.

  def signed_on_strict_client(rpc_bodies)
    c, broker = client_on_strict_broker([ "0\r7^DEMO.EXAMPLE.ORG^DEMO CLINIC\r\rGood evening USER,DEMO\r", "DUZ=63\r" ] + rpc_bodies)
    c.connect("localhost", 9100)
    c.authenticate("SYN123", "SYN123!!")
    [ c, broker ]
  end

  def test_voa_add_patient_hash_param_frames_as_quoted_subscript_triples
    c, broker = signed_on_strict_client([ "1^42\r\n" ])
    c.call_rpc("VAFC VOA ADD PATIENT",
      { "PRFCLTY" => "8994", "NAME" => "DEMOPATIENT^UNA", "SSN" => "" })
    assert_equal [ "UID", "", "7", "RPC", "", "VAFC VOA ADD PATIENT",
                   "1", "\"PRFCLTY\"", "8994",
                   "1", "\"NAME\"", "DEMOPATIENT^UNA",
                   "1", "\"SSN\"", "" ],
                 broker.frames.last[:fields]
  end

  def test_ddr_filer_frames_scalar_and_numeric_subscript_list_params
    c, broker = signed_on_strict_client([ "[Data]\r\n+1,^42\r\n" ])
    # FILEC^DDR3(DDRDATA,DDRMODE,DDRROOT,DDRFLAGS,DDRIENS): P1 mode literal,
    # P2 DDRROOT list, P3 flags literal, P4 DDRIENS list (DDR3.m:7).
    c.call_rpc("DDR FILER", "ADD", { 1 => "9000001^.01^+1,^42" }, "", { 1 => "42" })
    assert_equal [ "UID", "", "7", "RPC", "", "DDR FILER",
                   "1", "", "ADD",
                   "2", "1", "9000001^.01^+1,^42",
                   "3", "", "",
                   "4", "1", "42" ],
                 broker.frames.last[:fields]
  end

  def test_array_param_frames_as_one_based_numeric_subscripts
    c, broker = signed_on_strict_client([ "ok\r\n" ])
    c.call_rpc("XWB EXAMPLE GET LIST", [ "alpha", "beta" ])
    assert_equal [ "UID", "", "7", "RPC", "", "XWB EXAMPLE GET LIST",
                   "1", "1", "alpha",
                   "1", "2", "beta" ],
                 broker.frames.last[:fields]
  end

  def test_hash_param_doubles_embedded_quotes_in_string_subscripts
    c, broker = signed_on_strict_client([ "ok\r\n" ])
    c.call_rpc("XWB EXAMPLE ECHO STRING", { 'A"B' => "x" })
    assert_equal [ "UID", "", "7", "RPC", "", "XWB EXAMPLE ECHO STRING",
                   "1", "\"A\"\"B\"", "x" ],
                 broker.frames.last[:fields]
  end

  # -- first sign-on must request a FRESH session UID (0), not reconnect to 1 --
  #
  # AUTH^CIANBRPC branches on the UID param the client sends (CIANBRPC.m:47-60):
  #   UID > 0  → RECONNECT to that session — re-validates DUZ against the stored
  #              session and, on mismatch, CHK(27,4,UID) sets DATA(0)=4 with
  #              "reconnection attempt for session #1 has failed. The session
  #              was authenticated for a different user.", zeroes DUZ, and binds
  #              NO context (CIANBRPC.m:52).
  #   UID = 0  → else-branch ALLOCATES a fresh session, CIA("UID")=$$UID^CIANBUTL
  #              (CIANBRPC.m:58-59), returns it in DATA(1) piece 1, binds context.
  # A client that hard-codes UID "1" therefore hits the reconnect path on any box
  # that already has a session #1 (the live bcer-9.0-ydb evidence: session #1 was
  # MANAGER,SYSTEM) — the reply still carries a "Good morning" intro line, so the
  # greeting check falsely passes while session_uid stays nil and every gated RPC
  # returns "Access denied for remote procedure." A first sign-on MUST pass UID 0.
  #
  # This broker enforces that: it rejects an AUTH frame whose UID is anything but
  # "0" with the real reconnect-failure reply (verbatim from the evidence
  # transcript), and answers UID "0" by allocating session 7.
  class UidGatedCiaBrokerSocket < StrictCiaBrokerSocket
    # Verbatim shape of the live reconnect-failure reply (rpms-ops evidence,
    # releases/evidence/bcer-9.0-ydb-vuecentric.json "signon"): DATA(0)="4^<msg>",
    # DATA(1)="server^volume^UCI^port" (NON-numeric piece 1), DATA(2)=intro text
    # (which still contains a "Good morning" greeting).
    RECONNECT_FAIL = "4^The reconnection attempt for session #1 has failed.  " \
      "The session was authenticated for a different user.\r" \
      ".gtm_sysid^ROU^VEH^9100\r\r" \
      "Good morning MANAGER,SYSTEM.     You last signed on Oct 09, 2018 at 10:58\r"
    SIGNON_OK = "0\r7^DEMO.EXAMPLE.ORG^DEMO CLINIC\r\rGood evening USER,DEMO\r"

    attr_reader :reconnect_attempted

    def initialize
      super([])
      @reconnect_attempted = false
    end

    private

    # Same framing as the parent, but the reply BODY is chosen from the frame's
    # own fields (UID + RPC name) instead of a canned queue.
    def body_for(frame)
      return CONNECT_BODY if frame[:action] == "C"

      f = frame[:fields]
      uid = f[2] # UID / "" / <value>
      rpc = f[5] # RPC / "" / <name>
      case rpc
      when "CIANBRPC AUTH"
        if uid == "0"
          SIGNON_OK
        else
          @reconnect_attempted = true
          RECONNECT_FAIL
        end
      when "CIANBRPC GETVAR" then "DUZ=63\r\n"
      else "ok\r\n"
      end
    end

    public

    def write(str)
      return str.bytesize if @closed_by_broker

      frame = parse_frame(str.b)
      if frame.nil?
        @closed_by_broker = true
        @pending.clear
        return str.bytesize
      end
      @frames << frame
      @pending << frame[:seq]
      @pending << "\x00" + body_for(frame) + EOD
      str.bytesize
    end
  end

  def test_first_signon_requests_uid_zero_and_binds_a_fresh_session
    c = Client.new
    broker = UidGatedCiaBrokerSocket.new
    c.define_singleton_method(:open_socket) { |_h, _p| @socket = broker }
    c.instance_variable_set(:@timeout, 5)

    c.connect("localhost", 9100)
    result = c.authenticate("SYN123", "SYN123!!")

    # The AUTH frame must carry UID "0" (fresh allocate), not "1" (reconnect).
    auth_frame = broker.frames.find { |fr| fr[:fields].include?("CIANBRPC AUTH") }
    assert_equal "0", auth_frame[:fields][2], "first sign-on must request session UID 0, not reconnect to 1"
    refute broker.reconnect_attempted, "a UID-1 first sign-on takes the reconnect-failure path"

    # And the broker-allocated UID must be captured and carried thereafter.
    assert result[:success]
    assert_equal "7", c.session_uid, "client must adopt the broker-allocated session UID"
    assert_equal 63, result[:duz]

    broker_bodies_before = broker.frames.length
    c.call_rpc("BEHOPTCX PTINFO", "1")
    assert_equal "7", broker.frames.last[:fields][2], "later frames must carry the allocated UID"
    assert_operator broker.frames.length, :>, broker_bodies_before
  end

  # Regression class: a client that does not speak {CIA} is CLOSED by the CIA
  # broker, surfacing as "Connection closed by server" with no step completed.
  # This is what running the pre-rename XWB-protocol CiaClient against the
  # live CIANBLIS broker looks like — pin it offline so a wrong-protocol (or
  # corrupted-framing) connect can never look like a healthy suite again.
  def test_wrong_protocol_client_is_closed_by_strict_cia_broker
    c = RpmsRpc::XwbClient.new
    socket = StrictCiaBrokerSocket.new
    c.define_singleton_method(:open_socket) { |_h, _p| @socket = socket }
    c.instance_variable_set(:@timeout, 5)
    err = assert_raises(RpmsRpc::Client::ConnectionError) { c.connect("localhost", 9100) }
    assert_match(/Connection closed by server/, err.message)
    assert_empty socket.frames, "an [XWB]1130 frame must not parse as {CIA}"
    refute c.connected?
  end
end
