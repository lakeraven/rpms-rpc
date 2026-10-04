# frozen_string_literal: true

require "rpms_rpc/client"

module RpmsRpc
  # BMX (M Transfer) Protocol Client.
  #
  # Implements the {BMX} protocol used by BMXMON. BMXMON takes its port as an argument
  # (FOIA sets none); 9101 is the BMX port on hosted RPMS stacks (rpms-ops docs/BROKER-PORTS.md).
  # 9200 on those stacks is the IRIS CIA listener, a different protocol.
  # Both BMX and CIA/XWB route to the same RPC registry (^XWB(8994))
  # and call the same M routines — the difference is the wire format.
  #
  #   Session packet: {BMX} + TTTTT + PPPPP + body   (TTTTT = PPPPP+5; see
  #                   #send_bmx_session_packet and SESSMAIN's #11/#4/#PLEN reads)
  #   body          = proto_header + message         (NO separator: PRSP reads
  #                   MESG immediately after the fixed header fields)
  #   proto_header  = NNN + "WKID;WINH;PRCH;WISH;"    (NNN = 3-digit field length)
  #   message       = LLLLL + FLAG + text            (PRSM: 5-digit len, 1 flag
  #                   byte, text; FLAG "0" = literal params)
  #   text          = RPC_NAME  |  RPC_NAME + "^" + param_block  (PRSA splits at
  #                   the FIRST "^")
  #   param_block   = MMMMM + (LLL + TYPE + value)*  (PRSB: 5-digit total, then
  #                   per param a 3-digit (value_len+1), a 1-byte type "0"=literal,
  #                   then the value — read BY LENGTH, so a value may contain "^")
  #   Handshake:      monitor TCPconnect spawns a child session (no reply); a
  #                   SESSION-framed TCPconnect draws "accept"+EOT from the child
  #   Disconnect:     #BYE#
  #   Response:       len(security_err) + len(app_err) + data + EOT(\x04)
  #
  # Framing proven on a local IRIS container of a built 9.0 image, 2026-10-02
  # (rpms-rpc#282): the earlier single-step connect and the caret-separated,
  # ";1"-flagged message both failed the stock parser; the forms above resolve
  # the RPC and reach dispatch, and an AG rejection returns in the security packet.
  #
  # See FOIA-RPMS/Packages/M Transfer/Routines/BMXMON.m, BMXMBRK.m, BMXMBRK2.m
  class BmxClient < Client
    BMX_PREFIX = "{BMX}"

    # Connect to RPMS BMX Broker — a TWO-STEP handshake.
    #
    # The monitor read loop (MON/CONNECT^BMXMON) reads a {BMX}-framed "TCPconnect",
    # JOBs a child SESSION process and HANDS IT the socket — the parent writes
    # nothing back (BMXMON.m:118-126). The child's SESSMAIN loop then answers a
    # SESSION-framed "TCPconnect" with "accept"+EOT (BMXMON.m:215-216). One
    # TCPconnect is not enough: the parent spawns the child and the child blocks
    # on its first #11 read, so a client that sends one packet and reads hangs.
    #
    # Synchronized: a reconnect that replaces @socket while another caller is
    # mid-read hands that caller a stream it never wrote to.
    def connect(host = @host, port = @port)
      synchronize_wire do
        open_socket(host, port)

        send_bmx_packet("TCPconnect")          # monitor: spawn the session child
        send_bmx_session_packet("TCPconnect")  # child SESSMAIN: answers "accept"
        response = read_response

        if response.include?("accept") || response.include?("CONNECTION OK")
          @connected = true
        else
          @socket&.close
          @socket = nil
          raise ConnectionError, RpmsRpc.sanitize_error("BMX server rejected handshake: #{response}")
        end

        @connected
      end
    end

    # Disconnect from RPMS BMX Broker
    # Synchronized: an unsynchronized teardown injects #BYE# into, or closes the
    # socket under, another caller's in-flight RPC.
    def disconnect
      synchronize_wire do
        if connected?
          begin
            send_bmx_session_packet("#BYE#")
          rescue StandardError
            # Best effort disconnect
          end
        end
        reset_connection
      end
    end

    # Call an RPC via BMX protocol
    def call_rpc(rpc_name, *params)
      raise ConnectionError, "Not connected" unless connected?

      reject_unsupported_params(params)

      # Atomic send-then-read, with the frame built and the connection
      # re-checked INSIDE the lock, and the socket torn down before release if
      # the read times out. See Client#wire_operation.
      response = wire_operation do
        send_bmx_session_packet(build_bmx_message(rpc_name, params))
        read_response
      end
      check_for_rpc_error(response)
      split_response(response)
    rescue IOError, Errno::ECONNRESET, Errno::EPIPE, Errno::ENOTCONN => e
      @connected = false
      raise ConnectionError, "Connection lost during RPC call: #{e.message}"
    rescue Errno::ETIMEDOUT => e
      raise ConnectionError, "RPC call timed out: #{e.message}"
    rescue SocketError => e
      @connected = false
      raise ConnectionError, "Network error during RPC call: #{e.message}"
    end

    # Send an RPC and return the raw string response
    def call_rpc_raw(rpc_name, *params)
      raise ConnectionError, "Not connected" unless connected?

      reject_unsupported_params(params)

      wire_operation do
        send_bmx_session_packet(build_bmx_message(rpc_name, params))
        read_response
      end
    end

    # -- packet construction (public for testing) -----------------------------

    # BMX wire packets are byte streams. All length fields below count
    # BYTES, never characters. Buffers are built in ASCII-8BIT (binary)
    # so multibyte parameters frame correctly.

    # Build the BMX protocol frame body for an RPC call — the bytes that go
    # INSIDE a session packet (see #send_bmx_session_packet). Matches the stock
    # parse chain PRSP -> PRSM -> PRSA -> PRSB (BMXMBRK.m), proven on a live
    # stock broker (rpms-rpc#282):
    #
    #   proto_header = NNN + "WKID;WINH;PRCH;WISH;"   NNN = 3-digit field length
    #   message      = LLLLL + FLAG + text            5-digit len, 1 flag byte
    #   text         = RPC_NAME                       (no params), or
    #                  RPC_NAME + "^" + param_block   (PRSA splits at FIRST "^")
    #   param_block  = MMMMM + (LLL + TYPE + value)*  PRSB: 5-digit total, then
    #                  per param a 3-digit (value_len+1), type "0" (literal), value
    #
    # The proto_header is followed IMMEDIATELY by the message — PRSP reads MESG
    # as everything after the fixed header fields, with NO caret between them
    # (the previous "^" made PRSP see an empty protocol string). FLAG is a single
    # byte right after the 5-digit length (the previous ";1" put ";" in the flag
    # slot and glued "1" onto the RPC name).
    def build_bmx_message(rpc_name, params = [])
      proto_fields = "RPMS_RPC;0;0;0;".b
      proto_header = format("%03d", proto_fields.bytesize).b + proto_fields

      text = bmx_text(rpc_name, params)
      message = format("%05d", text.bytesize + 6).b + "0".b + text

      proto_header + message
    end

    # The PRSM "text": the RPC name, plus — when there are params — a "^" and the
    # PRSB-framed param block. PRSB reads each value BY LENGTH, so a value may
    # itself contain "^" (the earlier caret-joined scheme could not carry one).
    def bmx_text(rpc_name, params)
      name = rpc_name.to_s.b
      return name if params.empty?

      inner = params.map do |p|
        v = p.to_s.b
        format("%03d", v.bytesize + 1).b + "0".b + v # LLL=(len+1), TYPE "0"=literal
      end.join.b
      block = format("%05d", inner.bytesize).b + inner
      name + "^".b + block
    end

    private

    # BMX frames each param length-prefixed (PRSB, BMXMBRK.m:116-159), so a
    # SCALAR value crosses byte-safely — including one that contains "^" (PRSA
    # splits only at the FIRST caret, between the name and the block; everything
    # after is read by length). What this path does NOT build is the reference /
    # list-instantiation form (FLAG 1/2, the ".BMXS…" array splice), so Arrays
    # and Hashes are still rejected up front rather than stringified onto the
    # wire as a Ruby literal. RPCs with multi-line / list payloads (BEHOVM SAVE)
    # belong on XwbClient/CiaClient.
    def reject_unsupported_params(params)
      params.each_with_index do |p, i|
        next unless p.is_a?(Array) || p.is_a?(Hash)

        raise NotImplementedError,
              "BMX client does not yet support list/hash parameters " \
              "(param ##{i + 1} is #{p.class}). Use XwbClient/CiaClient for RPCs " \
              "with multi-line payloads (e.g. BEHOVM SAVE)."
      end
    end

    def default_port
      9101
    end

    # Send a packet for the initial monitor connection (pre-session)
    def send_bmx_packet(body)
      bytes = body.to_s.b
      length_str = format("%05d", bytes.bytesize).b
      packet = BMX_PREFIX.b + length_str + bytes
      send_packet(packet)
    end

    # Send a packet within an established session.
    # SESSMAIN (BMXMON.m lines 210-219) reads:
    #   R #11  → {BMX}(5) + LLLLL(5) + 1-byte overlap
    #   R #4   → remaining 4 bytes of PLEN
    #   R #PLEN → body
    # Wire = {BMX} + LLLLL + PPPPP + body
    def send_bmx_session_packet(body)
      bytes = body.to_s.b
      plen = format("%05d", bytes.bytesize).b
      total_len = format("%05d", bytes.bytesize + 5).b
      packet = BMX_PREFIX.b + total_len + plen + bytes
      send_packet(packet)
    end

    # Read BMX response: SNDERR packets + data + EOT
    #   byte(security_error_len) + security_error
    #   byte(app_error_len) + app_error
    #   data
    #   \x04 (EOT)
    def read_response
      raw = read_until_eot_raw
      return "" if raw.nil? || raw.empty?

      pos = 0

      # Security error packet
      if pos < raw.length
        sec_len = raw[pos].ord
        pos += 1
        if sec_len > 0 && pos + sec_len <= raw.length
          sec_err = raw[pos, sec_len]
          pos += sec_len
          unless sec_err.empty?
            # The security packet also carries the refusal of an RPC the broker
            # will not run (BMXMBRK.m:157-161, BMXMSEC.m:27): that is the typed
            # RpcNotAvailableError / RpcRefusedError every transport raises (#363),
            # not a broken connection.
            text = RpmsRpc.sanitize_error("BMX security error: #{sec_err}")
            error = Client.rpc_error_for(sec_err)
            raise error, text unless error == RpcError

            raise ConnectionError, text
          end
        end
      end

      # Application error packet
      if pos < raw.length
        app_len = raw[pos].ord
        pos += 1
        if app_len > 0 && pos + app_len <= raw.length
          app_err = raw[pos, app_len]
          pos += app_len
          unless app_err.empty?
            text = RpmsRpc.sanitize_error("BMX application error: #{app_err}")
            raise Client.rpc_error_for(app_err), text
          end
        end
      end

      pos < raw.length ? raw[pos..] : ""
    end
  end
end
