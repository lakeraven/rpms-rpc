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

    # S-PACK: chr(len) + value (max 255 chars)
    def spack(value)
      value.length.chr + value
    end

    # L-PACK: zero-padded length + value (3-digit for <=999, 5-digit for >999)
    def lpack(value)
      if value.length > 999
        format("%05d", value.length) + value
      else
        format("%03d", value.length) + value
      end
    end

    # Build TCPConnect command message — uses command token "4"
    def build_connect_message(client_hostname, app_name)
      command_token = "4"
      name_spec = spack("TCPConnect")
      param_spec = "5" \
        + "0" + lpack(client_hostname) + "f" \
        + "0" + lpack("0") + "f" \
        + "0" + lpack(app_name) + "f"
      (XWB_PREFIX + command_token + name_spec + param_spec + EOT).encode("UTF-8")
    end

    # Build an RPC invocation message — uses RPC token "2\x011"
    def build_rpc_message(name, params = nil)
      rpc_token = "2\x011"
      name_spec = spack(name)
      param_spec = "5"

      if params.nil? || params.empty?
        param_spec += "4f"
      else
        params.each do |p|
          case p[:type]
          when :literal
            param_spec += "0" + lpack(p[:value]) + "f"
          when :list
            param_spec += "2"
            first = true
            p[:entries].each do |key, val|
              param_spec += "t" unless first
              param_spec += lpack(key.to_s) + lpack(val.to_s)
              first = false
            end
            param_spec += "f"
          end
        end
      end

      (XWB_PREFIX + rpc_token + name_spec + param_spec + EOT).encode("UTF-8")
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
