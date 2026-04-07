# frozen_string_literal: true

require "rpms_rpc/client"

module RpmsRpc
  # BMX (M Transfer) Protocol Client.
  #
  # Implements the {BMX} protocol used by BMXMON on port 9200.
  # Both BMX and CIA/XWB route to the same RPC registry (^XWB(8994))
  # and call the same M routines — the difference is the wire format.
  #
  #   Packet format:  {BMX}LLLLL + protocol_header + message
  #   Handshake:      TCPconnect → "accept" (in session) or spawns child
  #   Disconnect:     #BYE#
  #   Response:       len(security_err) + len(app_err) + data + EOT(\x04)
  #
  # See FOIA-RPMS/Packages/M Transfer/Routines/BMXMON.m, BMXMBRK.m
  class BmxClient < Client
    BMX_PREFIX = "{BMX}"

    # Connect to RPMS BMX Broker
    def connect(host = @host, port = @port)
      open_socket(host, port)

      # BMX handshake: {BMX}LLLLL + TCPconnect
      body = "TCPconnect"
      send_bmx_packet(body)
      response = read_response

      if response.include?("accept") || response.include?("CONNECTION OK")
        @connected = true
      else
        @socket&.close
        @socket = nil
        raise ConnectionError, "BMX server rejected handshake: #{response}"
      end

      @connected
    end

    # Disconnect from RPMS BMX Broker
    def disconnect
      if connected?
        begin
          send_bmx_session_packet("#BYE#")
        rescue StandardError
          # Best effort disconnect
        end
      end
      reset_connection
    end

    # Call an RPC via BMX protocol
    def call_rpc(rpc_name, *params)
      raise ConnectionError, "Not connected" unless connected?

      param_string = params.map(&:to_s).join("^")
      api_content = rpc_name
      api_content += "^" + param_string unless param_string.empty?

      message = build_bmx_message(api_content)
      send_bmx_session_packet(message)

      response = read_response
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

      param_string = params.map(&:to_s).join("^")
      api_content = rpc_name
      api_content += "^" + param_string unless param_string.empty?

      message = build_bmx_message(api_content)
      send_bmx_session_packet(message)
      read_response
    end

    # -- packet construction (public for testing) -----------------------------

    # BMX wire packets are byte streams. All length fields below count
    # BYTES, never characters. Buffers are built in ASCII-8BIT (binary)
    # so multibyte parameters frame correctly.

    # Build BMX protocol message from API content.
    # Matches BMXMBRK.m PRSP/PRSM/PRSA parsing expectations:
    #   Protocol header: LLLwkid;winh;prch;wish;
    #   Message:         LLL;1 + API_NAME^PARAMS
    def build_bmx_message(api_content)
      proto_fields = "RPMS_RPC;0;0;0;".b
      proto_header = format("%03d", proto_fields.bytesize).b + proto_fields

      msg_body = api_content.to_s.b
      msg_header = (format("%05d", msg_body.bytesize + 6) + ";1").b
      message = msg_header + msg_body

      proto_header + "^".b + message
    end

    private

    def default_port
      9200
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
          raise ConnectionError, "BMX security error: #{sec_err}" unless sec_err.empty?
        end
      end

      # Application error packet
      if pos < raw.length
        app_len = raw[pos].ord
        pos += 1
        if app_len > 0 && pos + app_len <= raw.length
          app_err = raw[pos, app_len]
          pos += app_len
          raise RpcError, "BMX application error: #{app_err}" unless app_err.empty?
        end
      end

      pos < raw.length ? raw[pos..] : ""
    end
  end
end
