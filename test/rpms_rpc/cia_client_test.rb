# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/cia_client"
require "rpms_rpc/xwb_client"
require "rpms_rpc/version"
require "rpms_rpc/api/agg"

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

  # A refused sign-on leaves NOTHING bound. Asserting only `duz` is vacuous:
  # @duz is assigned after the gate, so it is nil on every refusal path whether
  # or not state was cleared. @authenticated, @session_uid, @current_context and
  # @signon_user are set BEFORE the identity read — they are what a refusal has
  # to unwind, and what a missing clear_signon_state would leave behind.
  def assert_signed_off(client)
    refute client.authenticated?, "a refused sign-on must not stay authenticated"
    assert_nil client.duz
    assert_nil client.session_uid, "a refused sign-on must not keep the broker session UID"
    assert_nil client.signon_user, "a refused sign-on must not leave a user name readable"
    assert_nil client.instance_variable_get(:@current_context),
      "a refused sign-on must not leave the sign-on context bound"
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
  # lines 3+ greeting. DUZ is NOT in the reply, and the session environment it
  # is saved into cannot be read back by the client (GETVAR^CIANBRPC forces an
  # empty or zero namespace to "@"; the sign-on DUZ lives in namespace 0). It is
  # asked for with XUS GET USER INFO, whose first line is the DUZ. The fixture
  # below is the shape a live broker returned on 2026-09-21.

  AUTH_REPLY = "1\x000\r\n7^DEMO.EXAMPLE.ORG^DEMO CLINIC\r\n\r\n" \
               "Good evening USER,DEMO\r\n     You last signed on today at 08:15\r\n"
  USERINFO_REPLY = "2\x0063\r\nUSER,DEMO\r\nDemo User\r\n1^DEMO CLINIC^1234\r\nIRM\r\n99999\r\n"

  def test_authenticate_populates_duz_from_user_info
    c = connected_client([ AUTH_REPLY + EOD, USERINFO_REPLY + EOD ])
    result = c.authenticate("SYN123", "SYN123!!")
    assert result[:success]
    assert_equal "USER,DEMO", result[:user]
    assert_equal 63, result[:duz]
    assert_equal "63", c.duz
  end

  def test_authenticate_captures_session_uid_and_uses_it_on_later_calls
    c = connected_client([ AUTH_REPLY + EOD, USERINFO_REPLY + EOD, "3\x00ok\r\n" + EOD ])
    c.authenticate("SYN123", "SYN123!!")
    assert_equal "7", c.session_uid
    c.call_rpc("CIANBRPC CANRUN", "XUS INTRO MSG")
    # UID field of the post-auth frame carries the broker-assigned session UID
    assert_includes c.instance_variable_get(:@socket).writes.last, "\x03UID\x00\x017".b
  end

  # The YDB-served broker (rpms-ydb-9.0, live 2026-09-03) separates reply
  # lines with bare CR, not CRLF — the session UID must still be adopted.
  def test_authenticate_captures_session_uid_from_cr_only_reply_lines
    cr_auth = "1\x001^VERIFY CODE must be changed before continued use.\r" \
              "35^DEMO.EXAMPLE.ORG^DEMO CLINIC\r\rGood evening USER,DEMO\r" \
              "     You last signed on today at 08:15\r"
    c = connected_client([ cr_auth + EOD, "2\x0063\rUSER,DEMO\rDemo User\r" + EOD, "3\x00ok\r" + EOD ])
    c.authenticate("SYN123", "SYN123!!")
    assert_equal "35", c.session_uid
    assert_equal "63", c.duz
    c.call_rpc("CIANBRPC CANRUN", "XUS INTRO MSG")
    assert_includes c.instance_variable_get(:@socket).writes.last, "\x03UID\x00\x0235".b
  end

  # #245: a greeting-only sign-on that resolves no DUZ is a refusal, not a
  # success with a nil identity. XUS GET USER INFO answers with an empty body.
  def test_authenticate_fails_closed_when_user_info_lacks_duz
    c = connected_client([ AUTH_REPLY + EOD, "2\x00\r\n" + EOD ])
    assert_raises(RpmsRpc::Client::AuthenticationError) { c.authenticate("SYN123", "SYN123!!") }
  end

  # Fix (#251 Copilot): the seq echo is not a field. A no-data reply (SNDEOD: sequence echo, no
  # \x00 DATA flag) framed by hand — split on "\x00", fall back to the whole
  # raw — leaves the echo as line 1, and a bare digit echo reads as a positive
  # DUZ. Sign-on would then attest identity "2" for a user the broker never
  # resolved. #parse_cia_reply exists to make that unrepresentable; signon_duz
  # must go through it.
  def test_authenticate_never_mints_the_sequence_echo_into_a_duz
    c = connected_client([ AUTH_REPLY + EOD, "2" + EOD ]) # seq echo only, no flag
    assert_raises(RpmsRpc::Client::AuthenticationError) { c.authenticate("SYN123", "SYN123!!") }
    assert_signed_off(c)
  end

  # Fix (#251, found verifying the Copilot finding above): a broker error reply
  # (\x01 + CIAERR text) is a failure to resolve identity,
  # and parse_cia_reply raises RpcError on it — sign-on must not swallow that
  # into a silent nil DUZ or let it escape as something other than a refusal.
  def test_authenticate_fails_closed_when_user_info_errors
    c = connected_client([ AUTH_REPLY + EOD, "2\x01CIAERR: no such RPC\r\n" + EOD ])
    assert_raises(RpmsRpc::Client::AuthenticationError) { c.authenticate("SYN123", "SYN123!!") }
    assert_signed_off(c)
  end

  # Fix (#251 Fable gate, F3): parse_cia_reply's "an unknown flag byte is NEVER
  # data" guard had no test — mutating its `else ""` to return the body left all
  # 1432 green. These pin it from the sign-on side, where minting a field out of
  # an unrecognised frame means minting an identity.
  def test_authenticate_fails_closed_on_a_reply_with_no_flag_byte
    c = connected_client([ AUTH_REPLY + EOD, "263\r\n" + EOD ]) # seq echo, then a body, no flag
    assert_raises(RpmsRpc::Client::AuthenticationError) { c.authenticate("SYN123", "SYN123!!") }
    assert_signed_off(c)
  end

  def test_authenticate_fails_closed_on_an_unrecognised_flag_byte
    c = connected_client([ AUTH_REPLY + EOD, "2\x0263\r\n" + EOD ]) # \x02 is neither DATA nor ERROR
    assert_raises(RpmsRpc::Client::AuthenticationError) { c.authenticate("SYN123", "SYN123!!") }
    assert_signed_off(c)
  end

  # A DUZ=0 reply (broker's "no user") is absence of identity too, not a
  # positive resolution — must fail closed the same way.
  def test_authenticate_fails_closed_on_zero_duz
    c = connected_client([ AUTH_REPLY + EOD, "2\x000\r\n" + EOD ])
    assert_raises(RpmsRpc::Client::AuthenticationError) { c.authenticate("SYN123", "SYN123!!") }
  end

  # A failed sign-on must leave NO half-bound session behind: a later caller
  # must not ride @authenticated/@session_uid/@current_context set before the
  # DUZ read.
  def test_authenticate_rolls_back_session_state_on_duz_failure
    c = connected_client([ AUTH_REPLY + EOD, "2\x00\r\n" + EOD ])
    assert_raises(RpmsRpc::Client::AuthenticationError) { c.authenticate("SYN123", "SYN123!!") }
    refute c.authenticated?
    assert_nil c.duz
    assert_nil c.session_uid
    assert_nil c.signon_user
  end

  # #245 (found in review): the process-global client is reused across
  # sign-ons, so a FAILED re-auth must not leave a PRIOR user's identity
  # readable. Pre-seed a resolved session, then fail a re-auth on no DUZ:
  # duz/authenticated/session_uid must all clear, not survive.
  def test_failed_reauth_clears_prior_users_identity
    c = connected_client([ AUTH_REPLY + EOD, USERINFO_REPLY + EOD,
                           AUTH_REPLY + EOD, "4\x00\r\n" + EOD ])
    first = c.authenticate("USERA", "USERA!!") # resolves DUZ 63
    assert_equal 63, first[:duz]
    assert_equal "63", c.duz

    assert_raises(RpmsRpc::Client::AuthenticationError) { c.authenticate("USERB", "USERB!!") }
    refute c.authenticated?, "a failed re-auth must not stay authenticated as the prior user"
    assert_nil c.duz, "a failed re-auth must not leave the prior user's DUZ readable"
    assert_nil c.session_uid
    assert_nil c.signon_user
  end

  # Same fail-closed contract for the greeting-rejection branch: a rejected
  # re-auth (bad code) must also clear a prior resolved identity.
  def test_rejected_reauth_clears_prior_users_identity
    rejected = "3\x00Not a valid ACCESS CODE/VERIFY CODE pair.\r\n"
    c = connected_client([ AUTH_REPLY + EOD, USERINFO_REPLY + EOD, rejected + EOD ])
    c.authenticate("USERA", "USERA!!")
    assert_equal "63", c.duz

    assert_raises(RpmsRpc::Client::AuthenticationError) { c.authenticate("BAD", "BAD!!") }
    refute c.authenticated?
    assert_nil c.duz
    assert_nil c.session_uid
  end

  # ADR 0002/0003 real-reply check (#245): the no-DUZ case in dispute is not a
  # synthetic fiction. This is the VERBATIM reply the live YDB-served broker
  # (rpms-ydb-9.0, :9100 via CIANBRPC GETVAR "DUZ") returns for a session with
  # a DUZ in its environment — captured 2026-09-21. "DUZ=" with no digits is
  # ALL that RPC can ever return (GETVAR^CIANBRPC cannot reach namespace 0),
  # which is why sign-on now asks XUS GET USER INFO instead. Kept as a
  # regression fixture: should anything route the identity read back through
  # GETVAR, sign-on must refuse rather than attest a nil identity.
  GETVAR_NO_DUZ_REAL = "2\x00DUZ=\r" # bytes [50,0,68,85,90,61,13] — rpms-ydb-9.0
  def test_authenticate_fails_closed_on_real_broker_no_duz_reply
    c = connected_client([ AUTH_REPLY + EOD, GETVAR_NO_DUZ_REAL + EOD ])
    assert_raises(RpmsRpc::Client::AuthenticationError) { c.authenticate("SYN123", "SYN123!!") }
    refute c.authenticated?
    assert_nil c.duz
  end

  # Fix (#251 Fable gate, F4): a connection torn down mid-sign-on cleared
  # @authenticated, @duz, @session_uid and the context, but NOT @signon_user —
  # so a client that reported itself signed off still named a clinician through
  # the public reader, and a later failed re-auth left the PRIOR user's name
  # readable. A wrong actor is worse than an absent one.
  def test_connection_loss_does_not_leave_a_user_name_readable
    c = connected_client([ AUTH_REPLY + EOD, USERINFO_REPLY + EOD ])
    c.authenticate("SYN123", "SYN123!!")
    assert_equal "USER,DEMO", c.signon_user

    c.instance_variable_get(:@socket).define_singleton_method(:recv) { |_n| "" } # peer closed
    assert_raises(RpmsRpc::Client::ConnectionError) { c.call_rpc("ANY RPC") }
    refute c.authenticated?
    assert_nil c.signon_user, "a torn-down connection must not keep naming a clinician"
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
      eod_byte = EOD.getbyte(0)
      while i < bytes.bytesize
        hdr = bytes.getbyte(i)
        # TCPREADL reads the L() header byte FIRST and ends the field list the
        # instant that byte equals CIA("EOD") — `Q:X=CIA("EOD") ""`
        # (CIANBLIS.m:233). It does NOT know whether this is the real trailing
        # terminator or a field length-prefix that merely collides with it; a
        # value whose L() header `(nlen<<4)|(len%16)` equals the EOD byte
        # (e.g. a 30-byte value → `\x1e`) truncates the frame right here. The
        # leftover bytes are then read as the next DOACTION's header, fail the
        # `{CIA}` check, and the session is closed — exactly the two-FILER drop.
        break if hdr == eod_byte

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
      # A well-formed frame's field list ends exactly on the trailing EOD (the
      # last byte). If an INTERIOR header byte collided with EOD, the loop broke
      # early and `i` points before the last byte — leftover the real broker
      # reads as a non-{CIA} frame → session close.
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
      "0\r\n7^DEMO.EXAMPLE.ORG^DEMO CLINIC\r\n\r\nGood evening USER,DEMO\r\n", # CIANBRPC AUTH
      "63\r\nUSER,DEMO\r\n",                                                     # XUS GET USER INFO
      "ok\r\n"                                                                 # the RPC proper
    ])
    c.connect("localhost", 9100)
    result = c.authenticate("SYN123", "SYN123!!")
    assert result[:success]
    assert_equal 63, result[:duz]
    assert_equal "7", c.session_uid
    assert_equal "4 ok  ", c.call_rpc("XWB IM HERE") # "4" seq echo + \x00 ack + body, printables
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
    c, broker = client_on_strict_broker([ "0\r\n7^DEMO.EXAMPLE.ORG^DEMO CLINIC\r\n\r\nGood evening USER,DEMO\r\n", "63\r\nUSER,DEMO\r\n" ] + rpc_bodies)
    c.connect("localhost", 9100)
    c.authenticate("SYN123", "SYN123!!")
    [ c, broker ]
  end

  # -- CIA context binding (rpms-rpc#225) -------------------------------------
  #
  # CIA carries the context as a CTX field on the RPC frame — DOACTION^CIANBLIS
  # reads any non-numeric field name into CIA(<NAME>) and names CTX among them
  # (CIANBLIS.m:165,168); ACTR^CIANBACT persists it (SETVAR^CIANBUTL, :50),
  # reuses the persisted value when a frame omits one (:49), and gates every
  # non-CIANB* RPC on it (:55). So binding a context costs no round trip, and
  # once bound the field must ride EVERY frame or a later "restore" is a no-op.

  def test_create_context_binds_without_a_round_trip
    c, broker = signed_on_strict_client([])
    frames_before = broker.frames.length

    assert c.create_context("AGGRPC")
    assert_equal "AGGRPC", c.current_context
    assert_equal frames_before, broker.frames.length,
      "CIA binds context on the next RPC frame — no XWB CREATE CONTEXT call"
  end

  def test_bound_context_rides_every_later_frame
    c, broker = signed_on_strict_client([ "1\r\n", "1\r\n" ])
    c.create_context("AGGRPC")

    c.call_rpc("CIANBRPC CANRUN", "AGG ADD NEW PATIENT")
    assert_equal [ "UID", "", "7", "CTX", "", "AGGRPC",
                   "RPC", "", "CIANBRPC CANRUN", "1", "", "AGG ADD NEW PATIENT" ],
                 broker.frames.last[:fields]

    # Restoring must keep NAMING the context: ACTR would otherwise reuse the
    # persisted AGGRPC for a frame that carries no CTX (CIANBACT.m:49-50).
    c.create_context(RpmsRpc::CiaClient::SIGNON_CONTEXT)
    c.call_rpc("CIANBRPC CANRUN", "AGG ADD NEW PATIENT")
    assert_equal [ "UID", "", "7", "CTX", "", "CIANB MAIN MENU",
                   "RPC", "", "CIANBRPC CANRUN", "1", "", "AGG ADD NEW PATIENT" ],
                 broker.frames.last[:fields]
  end

  # -- L() length-prefix must never collide with the frame terminator --------
  #
  # rpms-rpc#241: over the wire, sign-on → VOA ADD → DDR GETS → first DDR FILER
  # all succeed, then the SECOND FILER drops the connection ("Connection closed
  # by server"). Root cause is purely wire-layer (the same FILEC^DDR3 succeeds
  # in-process): the second FILER carries a 30-byte list-param value, and pk()
  # packs its L() header as `(1<<4)|(30%16)` = `\x1e` — the SAME byte as the CIA
  # frame terminator. TCPREADL reads that header, matches `Q:X=CIA("EOD")`
  # (CIANBLIS.m:233), and ends the field list mid-frame; the leftover bytes
  # fail the next DOACTION's {CIA} check and the broker closes the session.
  #
  # The invariant: no value the client L()-packs may produce a header byte
  # equal to the terminator. The terminator's high nibble is the count of
  # length-quotient bytes; a value would need that many bytes to store its
  # length>>4, so a high nibble of 7 (`\x7f`) demands a >= 2**52-byte value —
  # impossible — while `\x1e`'s high nibble of 1 collides across the entire
  # common 16..4095-byte range whenever len % 16 == 14.
  def test_pk_header_never_equals_the_frame_terminator
    c = Client.new
    eod = RpmsRpc::Client::EOD.getbyte(0)
    # The exact witnessed trigger, plus every other length in the collision
    # class the old \x1e terminator hit (len % 16 == 14, one quotient byte).
    lengths = [ 30 ] + (0..300).to_a + (14..4094).step(16).to_a
    colliding = lengths.select { |len| c.send(:pk, "x" * len).getbyte(0) == eod }
    assert_empty colliding,
      "pk() emits a header byte == the frame terminator for value lengths #{colliding.inspect}; " \
      "the broker's TCPREADL would truncate the frame there (rpms-rpc#241)"
  end

  # End-to-end reproduction through the broker-faithful double: the two FILER
  # frames the registration round trip sends (rpms-ops#501). The second frame's
  # 30-byte P2(1) value is the #241 trigger — with a colliding terminator the
  # double truncates the frame and closes the session, exactly as the live
  # broker did.
  def test_second_filer_with_thirty_byte_value_survives_the_wire
    c, broker = signed_on_strict_client([ "[Data]\r+1,^990066\r", "[Data]\r+1,^7819\r" ])

    # First FILER — 22-byte P2(1) value, no collision (header \x16).
    c.call_rpc("DDR FILER", "ADD", { "1" => "9000001^.01^+1,^990066" }, "", { "1" => "990066" })
    assert_equal "R", broker.frames.last[:action]

    # Second FILER — P2(1) is exactly 30 bytes ("9000001.41^.01^+1,990066,^7819").
    # This is the frame that dropped the live connection.
    second = lambda do
      c.call_rpc("DDR FILER", "ADD",
        { "1" => "9000001.41^.01^+1,990066,^7819", "2" => "9000001.41^.02^+1,990066,^990066" },
        "", { "1" => "7819" })
    end

    assert_equal 30, "9000001.41^.01^+1,990066,^7819".bytesize, "guard: the trigger value is 30 bytes"
    refute_raises_connection_error(&second)
    # The broker parsed the whole frame: all four params present, P2 subscripted.
    fields = broker.frames.last[:fields]
    assert_includes fields, "9000001.41^.01^+1,990066,^7819"
    assert_includes fields, "9000001.41^.02^+1,990066,^990066"
  end

  def refute_raises_connection_error
    yield
  rescue RpmsRpc::Client::ConnectionError => e
    flunk "the frame dropped the connection (rpms-rpc#241): #{e.message}"
  end

  def test_frames_carry_no_ctx_before_any_context_is_bound
    c, broker = signed_on_strict_client([ "1^42\r\n" ])
    c.call_rpc("VAFC VOA ADD PATIENT", { "PRFCLTY" => "8994" })

    refute_includes broker.frames.last[:fields], "CTX",
      "until something binds a context, ACTR falls back to the sign-on AID (CIANBACT.m:51)"
  end

  def test_with_context_scopes_and_restores_the_binding
    c, broker = signed_on_strict_client([ "1\r\n" ])
    c.create_context("OR CPRS GUI CHART")

    inner = nil
    c.with_context("AGGRPC") do
      inner = c.current_context
      c.call_rpc("CIANBRPC CANRUN", "AGG ADD NEW PATIENT")
    end

    assert_equal "AGGRPC", inner
    assert_includes broker.frames.last[:fields], "AGGRPC"
    assert_equal "OR CPRS GUI CHART", c.current_context, "the caller's context is restored"
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
      "The session was authenticated for a different user.\r\n" \
      ".gtm_sysid^ROU^VEH^9100\r\n\r\n" \
      "Good morning MANAGER,SYSTEM.     You last signed on Oct 09, 2018 at 10:58\r\n"
    SIGNON_OK = "0\r\n7^DEMO.EXAMPLE.ORG^DEMO CLINIC\r\n\r\nGood evening USER,DEMO\r\n"

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
      when "XUS GET USER INFO" then "63\r\nUSER,DEMO\r\n"
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

  # -- AGG GLOBAL ARRAY reply framing (rpms-rpc#214) --------------------------
  #
  # The AGG registration RPCs (ADD^AGGPTADD etc.) return a GLOBAL ARRAY: a
  # typed header row, then $C(30) (RS)-separated data records, ending $C(31)
  # (US) before the frame EOD. Because RS == the CIA EOD (\x1e), the default
  # call_rpc read stops at the header — call_rpc_global_array reads to the US
  # sentinel instead. These frame the exact request P1/P2/P3 shape observed on
  # the wire (P3 = $C(28)-delimited NAME=VALUE PARMS) and parse the reply
  # layouts confirmed by the #214 live probe through RpmsRpc::Agg.

  # An ADD^AGGPTADD success reply, verbatim shape from the #214 probe: typed
  # header, one RS-terminated "1^^DFN" record, US end sentinel. The strict
  # socket appends the frame EOD.
  AGG_ADD_OK = "I00010RESULT^T00080MESSAGE^I00010DFN\x1e1^^9\x1e\x1f"
  AGG_ADD_REJECT = "I00010RESULT^T00080MESSAGE^I00010DFN\x1e-1^NAME is required\x1e\x1f"

  def test_call_rpc_global_array_frames_window_dfn_and_fs_delimited_parms
    c, broker = signed_on_strict_client([ AGG_ADD_OK ])
    parms = RpmsRpc::Agg.encode_parms("AGGPTLNM" => "PROBE", "AGGPTSEX" => "MALE")
    c.call_rpc_global_array("AGG ADD NEW PATIENT", "Mini Registration", "", parms)

    assert_equal [ "UID", "", "7", "RPC", "", "AGG ADD NEW PATIENT",
                   "1", "", "Mini Registration",
                   "2", "", "",
                   "3", "", "AGGPTLNM=PROBE\x1cAGGPTSEX=MALE" ],
                 broker.frames.last[:fields]
  end

  def test_call_rpc_global_array_reads_past_embedded_rs_to_the_us_sentinel
    # The default read_until_raw(EOD) would truncate at the header's RS; the
    # global-array read must return the whole reply so Agg can parse the data
    # record after it.
    c, = signed_on_strict_client([ AGG_ADD_OK ])
    raw = c.call_rpc_global_array("AGG ADD NEW PATIENT", "Mini Registration", "", "AGGPTLNM=PROBE")

    parsed = RpmsRpc::Agg.parse_reply(raw)
    assert_equal [ { result: "1", message: "", dfn: "9" } ], parsed[:records]
  end

  def test_agg_add_patient_end_to_end_success_over_strict_broker
    c, = signed_on_strict_client([ AGG_ADD_OK ])
    RpmsRpc.configure { |cfg| cfg.client = c }

    result = RpmsRpc::Agg.add_patient(params: { "AGGPTLNM" => "PROBE" })

    assert result[:success]
    assert_equal 9, result[:dfn]
  ensure
    RpmsRpc.reset!
  end

  def test_agg_add_patient_end_to_end_rejection_over_strict_broker
    c, = signed_on_strict_client([ AGG_ADD_REJECT ])
    RpmsRpc.configure { |cfg| cfg.client = c }

    result = RpmsRpc::Agg.add_patient(params: { "AGGPTLNM" => "" })

    refute result[:success]
    assert_equal :agg_rejected, result[:error]
    assert_match(/NAME is required/, result[:message])
  ensure
    RpmsRpc.reset!
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
