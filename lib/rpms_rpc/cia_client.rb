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
    # End-of-array sentinel for GLOBAL ARRAY (return type 4) replies — the
    # AGG registration RPCs (ADD^AGGPTADD etc.). Such a reply is a $C(30)
    # (RS)-separated series of typed records that ends with $C(31) (US)
    # before the frame's trailing EOD. Because RS == our EOD (\x1e), the
    # default read_until_raw(EOD) truncates the reply at the header row;
    # #call_rpc_global_array reads to the US sentinel instead. Wire contract
    # + capture provenance: RpmsRpc::Agg.
    AGG_ARRAY_END = "\x1f"

    # Context option bound by sign-on. AUTH^CIANBRPC takes the application ID
    # — the context option — as P1 and saves it as the session's AID
    # (CIANBRPC.m:22,27,62); ACTR^CIANBACT falls back to that AID when a frame
    # carries no CTX field (CIANBACT.m:49-51). So this is the option every RPC
    # is gated against until something binds another one.
    SIGNON_CONTEXT = "CIANB MAIN MENU"

    def default_port = 9100

    # Open the socket and perform the {CIA} connect handshake.
    def connect(host = @host, port = @port)
      open_socket(host, port) # base: sets @socket, raises ConnectionError on failure
      @seq = 0
      @session_uid = nil
      reset_context # a new session starts on whatever sign-on binds
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
    # AUTH^CIANBRPC reply shape (lines are CR+LF separated, after the 1-byte
    # sequence echo and \x00 ack): line 1 = status code ("0" = success),
    # line 2 = session params "UID^netname^sitename", lines 3+ = greeting.
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

      # AUTH and the GETVAR that reads back DUZ are one indivisible sequence:
      # the broker stores DUZ into the session environment at sign-on, so a
      # concurrent sign-on landing between them returns the OTHER clinician's
      # DUZ to this caller.
      synchronize_wire do
        reply = exchange("R", pk("UID"), pk(""), pk("0"),
          pk("RPC"), pk(""), pk("CIANBRPC AUTH"),
          pk("1"), pk(""), pk(SIGNON_CONTEXT),
          pk("4"), pk(""), pk(avc))
        greeting = printable(reply)
        unless greeting.match?(/signed on|Good (morning|afternoon|evening)/i)
          raise AuthenticationError, RpmsRpc.sanitize_error("CIA sign-on rejected")
        end

        @authenticated = true
        @signon_user = greeting[/\b([A-Z][A-Z.'-]*,[A-Z][A-Z.'-]*)/, 1]&.strip
        uid = session_params(reply)[0]
        @session_uid = uid if uid&.match?(/\A\d+\z/) # failure params are "server^volume^UCI^port"
        @current_context = SIGNON_CONTEXT # ContextScope — AUTH bound it as the AID
        @duz = printable(call_rpc_raw("CIANBRPC GETVAR", "DUZ"))[/\bDUZ=(\d+)/, 1]
        { success: true, user: @signon_user, duz: @duz&.to_i, greeting: greeting.strip }
      end
    end

    attr_reader :signon_user, :session_uid

    # Bind a context option.
    #
    # CIA carries the context as a **CTX field on each RPC frame**, not as a
    # separate call: DOACTION^CIANBLIS reads every non-numeric field name into
    # CIA(<NAME>) and names CTX among the known ones (CIANBLIS.m:165,168),
    # ACTR^CIANBACT persists it with SETVAR^CIANBUTL("CTX",…) (:50) and gates
    # every non-CIANB* RPC on it (:55). So a CIA context switch is a
    # client-side state change with NO round trip — and no XWB CREATE CONTEXT
    # (CRCONTXT^XWBSEC), which is itself a non-CIANB* RPC and so would have to
    # be registered to the option currently bound in order to change it.
    #
    # From here on every frame carries CTX. It has to: ACTR persists the CTX
    # it was given (:50) and reads it back from the session when a frame omits
    # one (:49), so a client that stopped sending CTX would silently stay on
    # the last option it named — a "restore" that never happened. Before the
    # first bind no CTX is sent at all, which leaves ACTR to fall back to the
    # sign-on AID (:51) exactly as it does today.
    #
    # Pair with ContextScope#with_context to scope + restore (RpmsRpc::Agg).
    def create_context(option_name = SIGNON_CONTEXT)
      raise ConnectionError, "Not connected" unless connected?
      raise AuthenticationError, "Not authenticated" unless authenticated?

      @current_context = option_name
      @context_bound = true # start naming CTX on every frame — see above
      # RPC registration is OPTION-scoped; capabilities probed under the
      # previous context may not hold under the new one.
      @capability_cache = nil
      true
    end

    # Call an RPC over the CIA broker, returning a printable (human-readable) response.
    # Literal string params, plus list params as Hash (named/numeric subscripts)
    # or Array (1-based numeric subscripts) — matching XwbClient's public
    # param convention.
    def call_rpc(rpc_name, *params)
      printable(call_rpc_raw(rpc_name, *params))
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

      exchange("R", *rpc_frame_fields(rpc_name, params))
    rescue TimeoutError
      handle_rpc_timeout(rpc_name)
    end

    # Call an RPC whose broker return type is GLOBAL ARRAY (type 4) and read
    # the whole reply to its $C(31) (US) end sentinel — see AGG_ARRAY_END.
    # The reply EMBEDS $C(30) (== EOD, \x1e) record separators, so the
    # default call_rpc/call_rpc_raw read stops at the typed header; use this
    # for the AGG registration RPCs (RpmsRpc::Agg). Returns the raw reply
    # (seq echo + \x00 ack + typed header + \x1e-separated records); parse
    # with RpmsRpc::Agg.parse_reply. Same param-encoding contract as
    # call_rpc_raw.
    def call_rpc_global_array(rpc_name, *params)
      raise ConnectionError, "Not connected" unless connected?

      exchange("R", *rpc_frame_fields(rpc_name, params), terminator: AGG_ARRAY_END)
    rescue TimeoutError
      handle_rpc_timeout(rpc_name)
    end

    def disconnect
      @session_uid = nil
      reset_context
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
    # Write a frame and read its reply. The pair is atomic (Client#synchronize_wire):
    # the CIA stream carries no correlation id, so an unlocked send-then-read lets a
    # concurrent caller consume this frame's reply — and @seq, which numbers the
    # frames, is shared mutable state besides.
    def exchange(action, *fields, terminator: EOD)
      synchronize_wire do
        @seq = @seq % 9 + 1
        msg = ("{CIA}" + EOD + @seq.to_s + action + fields.join + EOD).b
        @socket.write(msg)
        read_until_raw(terminator) # base: shared read loop; CIA EOD, or AGG US sentinel
      end
    end

    # Build the L()-packed UID/RPC/param fields shared by call_rpc_raw and
    # call_rpc_global_array. Param encoding per DOACTION^CIANBLIS
    # (CIANBLIS.m:128-134): scalar params are NAME/""/VALUE triples; a Hash
    # builds a subscripted list param (string subscripts M-quoted, numerics
    # bare); an Array builds 1-based numeric subscripts.
    def rpc_frame_fields(rpc_name, params)
      parts = [ pk("UID"), pk(""), pk(@session_uid || "1") ]
      # CTX names the context option this RPC is gated against
      # (CIANBLIS.m:165,168 -> CIA("CTX"); CIANBACT.m:50,55). Sent only once a
      # context has actually been bound through create_context — and then on
      # EVERY frame, because ACTR persists the last CTX it saw (:50) and reuses
      # it when a frame omits one (:49). Until then the field is absent and
      # ACTR falls back to the sign-on AID (:51).
      parts.concat([ pk("CTX"), pk(""), pk(@current_context.to_s) ]) if @context_bound
      parts.concat([ pk("RPC"), pk(""), pk(rpc_name) ])
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
      parts
    end

    # A CIA reply has no length framing — only the EOD terminator — so a
    # reply abandoned mid-read cannot be resynchronized: the broker will
    # eventually write the stale reply into the stream and corrupt every
    # later exchange. Close the socket (defined state: disconnected, not
    # authenticated) and raise a per-RPC timeout distinct from generic
    # connection loss so callers can reconnect + re-authenticate.
    def handle_rpc_timeout(rpc_name)
      @session_uid = nil
      reset_context
      reset_connection # base
      raise RpcTimeoutError, RpmsRpc.sanitize_error(
        "RPC '#{rpc_name}' timed out after #{@timeout}s; connection closed — reconnect and re-authenticate"
      )
    end

    # List-param subscript in M-literal form for DOACTION's raw splice into
    # P<n>(<SB>) (CIANBLIS.m DOACTION lines 128-134): canonic numerics stay
    # bare; anything else is quoted with embedded quotes doubled.
    # Forget the bound context. The CTX a frame carries is persisted into the
    # SESSION (SETVAR^CIANBUTL, CIANBACT.m:50), so a dead session takes the
    # binding with it — carrying the old value into a new one would name a
    # context this session never bound.
    def reset_context
      @current_context = nil
      @context_bound = false
    end

    def m_subscript(key)
      s = key.to_s
      s.match?(/\A-?(0|[1-9]\d*)(\.\d+)?\z/) ? s : %("#{s.gsub('"', '""')}")
    end

    def printable(str) = str.to_s.gsub(/[^\x20-\x7e]/, " ")

    # Split a raw {CIA} RPC reply into the "^"-pieces of its params line
    # (line 2; line 1 is the status code prefixed by the sequence echo and
    # ack byte, lines 3+ are message text). Returns [] when absent.
    #
    # Line separator: CRLF, bare CR, or bare LF — the YDB-served broker
    # (rpms-ydb-9.0, verified live 2026-09-03) writes reply lines with bare
    # CR; splitting only on CRLF/LF left the params line unfound, so the
    # broker-assigned session UID was never adopted and every later frame
    # carried the default UID (working only when the broker didn't enforce it).
    def session_params(reply)
      reply.to_s.split(/\r\n|\r|\n/)[1].to_s.split("^")
    end
  end
end
