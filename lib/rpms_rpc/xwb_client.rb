# frozen_string_literal: true

require "rpms_rpc/client"

module RpmsRpc
  # XWB stock-VistA RPC Broker client — the standard [XWB]1130 / XWBTCPM protocol
  # (CPRS and every non-IHS VistA speak this). Renamed from the misnomer `CiaClient`:
  # this is NOT the IHS CIA {CIA} protocol. For the CIA broker (CIANBLIS, what
  # VueCentric/RPMS-EHR use) see RpmsRpc::CiaClient.
  #
  # Implements the [XWB] RPC Broker protocol used by XWBTCPM on port 9100.
  #
  #   Packet format:  [XWB]1130 + token + spack(name) + params + EOT
  #   Handshake:      TCPConnect → "accept"
  #   Disconnect:     #BYE#
  #   Response:       \x00\x00 (SNDERR prefix) + data + EOT(\x04)
  #
  # See FOIA-RPMS/Packages/RPC Broker/Routines/XWBTCPM.m
  class XwbClient < Client
    XWB_PREFIX = "[XWB]1130"

    # Connect to RPMS XWB Broker.
    # Synchronized: a reconnect that replaces @socket while another caller is
    # mid-read hands that caller a stream it never wrote to.
    def connect(host = @host, port = @port)
      synchronize_wire do
        open_socket(host, port)

        send_packet(build_connect_message(local_ip, "rpms-rpc"))
        response = read_response

        if response.start_with?("accept")
          @connected = true
        else
          @socket&.close
          @socket = nil
          raise ConnectionError, RpmsRpc.sanitize_error("Server rejected handshake: #{response}")
        end

        @connected
      end
    end

    # Disconnect from RPMS XWB Broker
    # Synchronized: an unsynchronized teardown injects #BYE# into, or closes the
    # socket under, another caller's in-flight RPC.
    def disconnect
      synchronize_wire do
        if connected?
          begin
            send_packet(build_rpc_message("#BYE#"))
          rescue StandardError
            # Best effort disconnect
          end
        end
        reset_connection
      end
    end

    # Call an RPC via XWB protocol
    def call_rpc(rpc_name, *params)
      raise ConnectionError, "Not connected" unless connected?

      # Atomic send-then-read, with the frame built and the connection
      # re-checked INSIDE the lock, and the socket torn down before release if
      # the read times out — otherwise the next caller reads this call's late
      # reply as its own. See Client#wire_operation.
      response = wire_operation do
        send_packet(build_rpc_message(rpc_name, params.map { |p| encode_param(p) }))
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

      wire_operation do
        send_packet(build_rpc_message(rpc_name, params.map { |p| encode_param(p) }))
        read_response
      end
    end

    # Build disconnect packet (compatibility)
    def build_disconnect_packet
      build_rpc_message("#BYE#")
    end

    # -- packet construction (public for testing) -----------------------------

    # XWB wire packets are byte streams, not character strings. The broker
    # frames everything by byte count, so every length prefix and every
    # concatenated buffer below is built in ASCII-8BIT (binary) encoding.
    # The helpers below are byte-safe; do not introduce String#length here.

    # SpackTooLongError raised when a value exceeds S-PACK's 255-byte limit.
    class SpackTooLongError < StandardError; end

    # S-PACK: one-byte length prefix + value (max 255 bytes)
    def spack(value)
      bytes = value.to_s.b
      if bytes.bytesize > 255
        raise SpackTooLongError, "S-PACK value exceeds 255 bytes (#{bytes.bytesize})"
      end
      bytes.bytesize.chr.b + bytes
    end

    # L-PACK: zero-padded length + value (3-digit for <=999 bytes,
    # 5-digit for >999 bytes). Length is always counted in BYTES.
    def lpack(value)
      bytes = value.to_s.b
      width = bytes.bytesize > 999 ? 5 : 3
      (format("%0#{width}d", bytes.bytesize) + bytes).b
    end

    # Build TCPConnect command message — uses command token "4"
    def build_connect_message(client_hostname, app_name)
      command_token = "4"
      name_spec = spack("TCPConnect")
      param_spec = ("5" \
        + "0").b + lpack(client_hostname) + "f".b \
        + "0".b + lpack("0") + "f".b \
        + "0".b + lpack(app_name) + "f".b
      (XWB_PREFIX.b + command_token.b + name_spec + param_spec + EOT.b)
    end

    # Build an RPC invocation message — uses RPC token "2\x011"
    def build_rpc_message(name, params = nil)
      rpc_token = "2\x011".b
      name_spec = spack(name)
      param_spec = +"5".b

      if params.nil? || params.empty?
        param_spec << "4f".b
      else
        params.each do |p|
          case p[:type]
          when :literal
            param_spec << "0".b << lpack(p[:value]) << "f".b
          when :list
            param_spec << "2".b
            first = true
            p[:entries].each do |key, val|
              param_spec << "t".b unless first
              param_spec << lpack(key.to_s) << lpack(val.to_s)
              first = false
            end
            param_spec << "f".b
          end
        end
      end

      (XWB_PREFIX.b + rpc_token + name_spec + param_spec + EOT.b)
    end

    # Build a literal parameter hash
    def literal_param(value)
      { type: :literal, value: value }
    end

    # Build a list parameter hash
    def list_param(entries)
      { type: :list, entries: entries }
    end

    # Encode a single param for transport.
    # Already-wrapped {type: :literal|:list, ...} hashes pass through.
    # Arrays become list_params with 1-based string keys (the RPMS broker
    # convention for multi-line params like BEHOVM SAVE's payload).
    # Hashes become list_params with their keys/values as entries.
    # Everything else stringifies to a literal_param.
    def encode_param(value)
      # Pre-wrapped param hashes pass through, but only when their :type
      # is one of the protocol's known kinds. A normal business hash that
      # happens to have a :type key must still be encoded as a list_param.
      return value if value.is_a?(Hash) && %i[literal list].include?(value[:type])
      case value
      when Array
        entries = value.each_with_index.map { |v, i| [ (i + 1).to_s, v.to_s ] }
        list_param(entries)
      when Hash
        list_param(value.map { |k, v| [ k.to_s, v.to_s ] })
      else
        literal_param(value.to_s)
      end
    end

    private

    def default_port
      9100
    end

    # Read XWB response: recv until EOT, strip \x00\x00 SNDERR prefix
    def read_response
      raw = read_until_eot_raw
      raw = raw[2..] if raw.start_with?("\x00\x00")
      raw.to_s
    end
  end
end
