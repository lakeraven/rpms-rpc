# frozen_string_literal: true

require "rpms_rpc/client"

module RpmsRpc
  # XWB (CIA) Protocol Client.
  #
  # Implements the [XWB] RPC Broker protocol used by XWBTCPM on port 9100.
  #
  #   Packet format:  [XWB]1130 + token + spack(name) + params + EOT
  #   Handshake:      TCPConnect → "accept"
  #   Disconnect:     #BYE#
  #   Response:       \x00\x00 (SNDERR prefix) + data + EOT(\x04)
  #
  # See FOIA-RPMS/Packages/RPC Broker/Routines/XWBTCPM.m
  class CiaClient < Client
    XWB_PREFIX = "[XWB]1130"

    # Connect to RPMS XWB Broker
    def connect(host = @host, port = @port)
      open_socket(host, port)

      msg = build_connect_message(local_ip, "rpms-rpc")
      send_packet(msg)
      response = read_response

      if response.start_with?("accept")
        @connected = true
      else
        @socket&.close
        @socket = nil
        raise ConnectionError, "Server rejected handshake: #{response}"
      end

      @connected
    end

    # Disconnect from RPMS XWB Broker
    def disconnect
      if connected?
        begin
          msg = build_rpc_message("#BYE#")
          send_packet(msg)
        rescue StandardError
          # Best effort disconnect
        end
      end
      reset_connection
    end

    # Call an RPC via XWB protocol
    def call_rpc(rpc_name, *params)
      raise ConnectionError, "Not connected" unless connected?

      rpc_params = params.map { |p| literal_param(p.to_s) }
      msg = build_rpc_message(rpc_name, rpc_params)

      send_packet(msg)
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

      rpc_params = params.map { |p| literal_param(p.to_s) }
      msg = build_rpc_message(rpc_name, rpc_params)

      send_packet(msg)
      read_response
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
