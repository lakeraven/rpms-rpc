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
    # AUTH^CIANBRPC reply shape (lines are CR+LF separated, after the 1-byte
    # sequence echo and \x00 ack): line 1 = status code ("0" = success),
    # line 2 = session params "UID^netname^sitename", lines 3+ = greeting.
    # The reply carries the broker-assigned session UID but NOT the DUZ; the
    # broker saves DUZ into the session environment at sign-on, so it is
    # fetched with the context-exempt CIANBRPC GETVAR ("DUZ=n" reply).
    def authenticate(access_code = nil, verify_code = nil, **)
      raise ConnectionError, "Not connected" unless connected?

      ac, vc = resolve_credentials(access_code, verify_code) # base
      avc = xwb_encrypt("#{ac};#{vc}") # base cipher — matches ENCRYP^XUSRB1
      reply = exchange("R", pk("UID"), pk(""), pk("1"),
        pk("RPC"), pk(""), pk("CIANBRPC AUTH"),
        pk("1"), pk(""), pk("CIANB MAIN MENU"),
        pk("4"), pk(""), pk(avc))
      greeting = printable(reply)
      unless greeting.match?(/signed on|Good (morning|afternoon|evening)/i)
        raise AuthenticationError, RpmsRpc.sanitize_error("CIA sign-on rejected")
      end

      @authenticated = true
      @signon_user = greeting[/\b([A-Z][A-Z.'-]*,[A-Z][A-Z.'-]*)/, 1]&.strip
      uid = session_params(reply)[0]
      @session_uid = uid if uid&.match?(/\A\d+\z/) # failure params are "server^volume^UCI^port"
      @duz = printable(call_rpc_raw("CIANBRPC GETVAR", "DUZ"))[/\bDUZ=(\d+)/, 1]
      { success: true, user: @signon_user, duz: @duz&.to_i, greeting: greeting.strip }
    end

    attr_reader :signon_user, :session_uid

    # Call an RPC over the CIA broker, returning a printable (human-readable) response.
    # Literal string params (list/reference params TBD).
    def call_rpc(rpc_name, *params)
      printable(call_rpc_raw(rpc_name, *params))
    end

    # Send an RPC and return the raw, unmodified broker response. Client contract:
    # call_rpc_raw must not transform the payload (call_rpc applies printable()).
    def call_rpc_raw(rpc_name, *params)
      raise ConnectionError, "Not connected" unless connected?

      parts = [ pk("UID"), pk(""), pk(@session_uid || "1"), pk("RPC"), pk(""), pk(rpc_name) ]
      params.each_with_index { |p, i| parts.concat([ pk((i + 1).to_s), pk(""), pk(p.to_s) ]) }
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

    def printable(str) = str.to_s.gsub(/[^\x20-\x7e]/, " ")

    # Split a raw {CIA} RPC reply into the "^"-pieces of its params line
    # (line 2; line 1 is the status code prefixed by the sequence echo and
    # ack byte, lines 3+ are message text). Returns [] when absent.
    def session_params(reply)
      lines = reply.to_s.split("\r\n")
      lines = reply.to_s.split("\n") if lines.length <= 1
      lines[1].to_s.split("^")
    end
  end
end
