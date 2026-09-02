# frozen_string_literal: true

require "rpms_rpc/client"

module RpmsRpc
  # IHS **CIA** broker client — the `{CIA}` protocol served by CIANBLIS, which VueCentric /
  # RPMS-EHR speak. (The stock XWB `[XWB]1130` / XWBTCPM protocol is RpmsRpc::XwbClient; the
  # IHS BMX `{BMX}` protocol is RpmsRpc::BmxClient. Pick one with RpmsRpc.client_for.)
  #
  # DRY: everything shared lives in Client — the XUSRB1 cipher (`xwb_encrypt`), credential
  # resolution (`resolve_credentials`), the socket lifecycle (`open_socket`/`reset_connection`),
  # and the read loop (`read_until_raw`). This subclass adds only what is CIA-specific: the
  # `{CIA}` + EOD framing, the CIA length prefix, and the CIANBRPC AUTH sign-on.
  class CiaClient < Client
    def default_port = 9100

    # Open the socket and perform the {CIA} connect handshake.
    def connect(host = @host, port = @port)
      open_socket(host, port) # base: sets @socket, raises ConnectionError on failure
      @seq = 0
      @session_uid = nil
      @uci = ENV.fetch("RPMS_UCI", "VEH,EXTERNAL")
      reply = exchange("C", pk("VER"), pk(""), pk("2.0"),
        pk("LP"), pk(""), pk(port.to_s),
        pk("UCI"), pk(""), pk(@uci))
      raise ConnectionError, RpmsRpc.sanitize_error("CIA broker did not answer connect") if reply.empty?

      @connected = true
    rescue StandardError
      # A failed handshake (empty reply, timeout, write error) must not leak
      # the open socket or leave a half-initialized client behind a retry.
      reset_connection # base: close socket, defined disconnected state
      raise
    end

    # Sign on via CIANBRPC AUTH with a client-side-encrypted access;verify (AVC).
    #
    # AUTH^CIANBRPC reply shape (after #deframe strips the 1-byte sequence echo
    # and the \x00 ack, and normalizes the wire's bare-CR line delimiters to
    # LF — see #deframe): line 1 = status code ("0" = success), line 2 =
    # session params "UID^netname^sitename", lines 3+ = greeting.
    # The reply carries the broker-assigned session UID but NOT the DUZ; the
    # broker saves DUZ into the session environment at sign-on, so it is
    # fetched with the context-exempt CIANBRPC GETVAR ("DUZ=n" reply).
    #
    # A first sign-on MUST request session UID 0. AUTH^CIANBRPC branches on the
    # UID param (CIANBRPC.m:47-60): a non-zero UID is a RECONNECT to that session
    # and, when its stored DUZ does not match, CHK(27,4,UID) fails with
    # "reconnection attempt for session #1 has failed. The session was
    # authenticated for a different user.", zeroes DUZ and binds NO context
    # (CIANBRPC.m:52); UID 0 takes the else-branch that ALLOCATES a fresh session
    # (CIANBRPC.m:58-59, CIA("UID")=$$UID^CIANBUTL) and returns it in DATA(1)
    # piece 1. The client then adopts that broker-assigned UID (below) and
    # carries it on every later frame — without it, gated RPCs return "Access
    # denied for remote procedure."
    def authenticate(access_code = nil, verify_code = nil, **)
      raise ConnectionError, "Not connected" unless connected?

      ac, vc = resolve_credentials(access_code, verify_code) # base
      avc = xwb_encrypt("#{ac};#{vc}") # base cipher — matches ENCRYP^XUSRB1
      body = deframe(exchange("R", pk("UID"), pk(""), pk("0"),
        pk("RPC"), pk(""), pk("CIANBRPC AUTH"),
        pk("1"), pk(""), pk("CIANB MAIN MENU"),
        pk("4"), pk(""), pk(avc)))
      greeting = printable(body)
      unless greeting.match?(/signed on|Good (morning|afternoon|evening)/i)
        raise AuthenticationError, RpmsRpc.sanitize_error("CIA sign-on rejected")
      end

      @authenticated = true
      @signon_user = greeting[/\b([A-Z][A-Z.'-]*,[A-Z][A-Z.'-]*)/, 1]&.strip
      uid = session_params(body)[0]
      @session_uid = uid if uid&.match?(/\A\d+\z/) # failure params are "server^volume^UCI^port"
      @duz = call_rpc("CIANBRPC GETVAR", "DUZ")[/\bDUZ=(\d+)/, 1]
      { success: true, user: @signon_user, duz: @duz&.to_i, greeting: greeting.strip }
    end

    attr_reader :signon_user, :session_uid

    # Call an RPC over the CIA broker, returning the deframed, printable
    # (human-readable) response: the 1-byte sequence echo and \x00 ack the
    # broker prepends are stripped and the wire's bare-CR line delimiters are
    # normalized to LF, so multi-line replies (DDR LISTER / GETS / FILER) keep
    # their line structure for the parsers downstream (see #deframe).
    # Literal string params, plus list params as Hash (named/numeric subscripts)
    # or Array (1-based numeric subscripts) — matching XwbClient's public
    # param convention.
    def call_rpc(rpc_name, *params)
      printable(deframe(call_rpc_raw(rpc_name, *params)))
    end

    # Send an RPC and return the raw, unmodified broker response. Client contract:
    # call_rpc_raw must not transform the payload (call_rpc applies printable()).
    #
    # Param encoding: DOACTION^CIANBLIS reads NAME/SUBSCRIPT/VALUE triples of
    # L()-packed fields; a numeric NAME with an empty SUBSCRIPT sets the
    # scalar P<n>, and repeated triples with a non-empty SUBSCRIPT build the
    # list P<n>(<SUBSCRIPT>) — the subscript text is spliced RAW into the M
    # reference ('RT=RT_"("_SB_")"' then 'S @RT=VL', CIANBLIS.m DOACTION
    # lines 128-134), so string subscripts must cross the wire in M-quoted
    # form ("NAME", embedded quotes doubled) while numeric subscripts stay
    # bare. ACTR^CIANBACT then passes P1..Pn positionally, by reference, to
    # the RPC's tag^routine (DORPC^CIANBACT: CIANBACT.m:66-78).
    def call_rpc_raw(rpc_name, *params)
      raise ConnectionError, "Not connected" unless connected?

      parts = [ pk("UID"), pk(""), pk(@session_uid || "1"), pk("RPC"), pk(""), pk(rpc_name) ]
      params.each_with_index do |p, i|
        n = (i + 1).to_s
        case p
        when Hash
          p.each { |k, v| parts.concat([ pk(n), pk(m_subscript(k)), pk(v.to_s) ]) }
        when Array
          p.each_with_index { |v, j| parts.concat([ pk(n), pk((j + 1).to_s), pk(v.to_s) ]) }
        else
          parts.concat([ pk(n), pk(""), pk(p.to_s) ])
        end
      end
      exchange("R", *parts)
    rescue TimeoutError
      # A CIA reply has no length framing — only the EOD terminator — so a
      # reply abandoned mid-read cannot be resynchronized: the broker will
      # eventually write the stale reply into the stream and corrupt every
      # later exchange. Close the socket (defined state: disconnected, not
      # authenticated) and raise a per-RPC timeout distinct from generic
      # connection loss so callers can reconnect + re-authenticate.
      @session_uid = nil
      reset_connection # base
      raise RpcTimeoutError, RpmsRpc.sanitize_error(
        "RPC '#{rpc_name}' timed out after #{@timeout}s; connection closed — reconnect and re-authenticate"
      )
    end

    def disconnect
      @session_uid = nil
      reset_connection # base: closes the socket and clears state
    end

    def read_response = read_until_raw(EOD) # Client contract; CIA terminator

    private

    # CIA length prefix ("L()"): header byte = (num_length_bytes << 4) | (len % 16),
    # then the big-endian length-quotient bytes, then the value. CIA-specific (XWB uses
    # decimal spack/lpack), so it lives here, not in the base.
    def pk(value)
      v = value.to_s.b
      len = v.bytesize
      n = len % 16
      q = len >> 4
      lb = []
      x = q
      while x.positive?
        lb.unshift(x & 0xff)
        x >>= 8
      end
      (((lb.size << 4) | n).chr + lb.map(&:chr).join + v).b
    end

    # Assemble a {CIA} frame, send it, read the reply via the shared base read loop.
    # The header is fixed-width: DOACTION^CIANBLIS reads exactly 8 bytes
    # ("{CIA}" + EOD + 1-byte sequence + action) and echoes the sequence byte
    # back unmodified. The sequence must therefore always be exactly one byte —
    # a counter that reaches 10 would put "1" in the sequence slot and "0" in
    # the action slot, corrupting every frame from the tenth on — so cycle 1..9.
    def exchange(action, *fields)
      @seq = @seq % 9 + 1
      msg = ("{CIA}" + EOD + @seq.to_s + action + fields.join + EOD).b
      @socket.write(msg)
      read_until_raw(EOD) # base: shared read loop, CIA terminator
    end

    # List-param subscript in M-literal form for DOACTION's raw splice into
    # P<n>(<SB>) (CIANBLIS.m DOACTION lines 128-134): canonic numerics stay
    # bare; anything else is quoted with embedded quotes doubled.
    def m_subscript(key)
      s = key.to_s
      s.match?(/\A-?(0|[1-9]\d*)(\.\d+)?\z/) ? s : %("#{s.gsub('"', '""')}")
    end

    # Strip the CIA reply framing and normalize line structure. Empirically
    # (live wire, rpms-ydb-9.0 CIANBLIS on :9100, 2026-09-02) a reply is
    #
    #   <1-byte sequence echo><\x00 ack><body>
    #
    # where the body's own lines are delimited by a BARE CR (\x0d), not CRLF —
    # e.g. a DDR LISTER reply reads (hex, seq+ack elided):
    #   "[Data]\r4^DEMOPATIENT,REGTEST\r3^MOUSE,MICKEY M\r2^USER,TEST\r".
    # The old code neither stripped the seq/ack (so every parse saw a stray
    # leading "<seq> " and a corrupted first field) nor recognized bare-CR
    # delimiters — printable() flattened ALL of \r/\n/\x00 to spaces, collapsing
    # every multi-line DDR reply to one line and zeroing out session_params
    # (which is exactly why session_uid/DUZ came back nil, cascading the client
    # into a UID-1 reconnect). Deframe fixes both, ONCE, at the client layer:
    # drop the seq echo + ack, normalize CR / CRLF / LF to LF, drop the single
    # trailing delimiter. (#call_rpc_raw stays byte-exact — its contract is the
    # unmodified reply; deframing is call_rpc's / authenticate's job.)
    def deframe(raw)
      s = raw.to_s.b
      s = (s.byteslice(2..) || "".b) if s.bytesize >= 2 && s.getbyte(1) == 0
      s.gsub(/\r\n|\r|\n/, "\n").sub(/\n\z/, "")
    end

    # Replace non-printable bytes with spaces for human readability, but keep
    # the LF line structure #deframe established (so line-oriented reply parsers
    # still see their lines).
    def printable(str) = str.to_s.gsub(/[^\x20-\x7e\n]/, " ")

    # The "^"-pieces of a DEFRAMED reply's params line (line index 1; line 0 is
    # the status code, lines 2+ are message text). Returns [] when absent.
    def session_params(body)
      body.to_s.split("\n")[1].to_s.split("^")
    end
  end
end
