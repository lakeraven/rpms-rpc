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
    class SpackTooLongError < Error; end

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
    # Hashes become list_params with their keys/values as entries, each key
    # formed as an M subscript: LINST^XWBPRS splices it raw into
    # A_"("_X_")" (XWBPRS.m:152-156), so a string level is quoted (embedded
    # quotes doubled) and a canonic number stays bare. An Array key is a
    # multi-level subscript joined with commas ([1, 0] => "1,0", the TIUX(n,0)
    # TIU TEMPLATE GETTEXT reads; ["TEXT", 1, 0] => "\"TEXT\",1,0", the
    # TIUX("TEXT",n,0) TIU SET DOCUMENT TEXT reads) (#219).
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
        list_param(value.map { |k, v| [ m_subscript(k), v.to_s ] })
      else
        literal_param(value.to_s)
      end
    end

    private

    # Same subscript grammar as CiaClient#m_subscript.
    def m_subscript(key)
      return key.map { |level| m_subscript(level) }.join(",") if key.is_a?(Array)

      s = key.to_s
      s.match?(/\A-?(0|[1-9]\d*)(\.\d+)?\z/) ? s : %("#{s.gsub('"', '""')}")
    end

    def default_port
      9100
    end

    # Read XWB response: recv until EOT, then the SNDERR header every reply
    # carries (XWBRW.m:70-78): the security packet and the application packet,
    # each a length byte and its text, then the data. A refusal of the RPC
    # itself arrives as the security packet (XWBPRS.m:11-13): no #8994 entry
    # or inactive raises RpcNotAvailableError, not in the context option
    # raises RpcRefusedError; an application error raises RpcError (#363). Reading the header by its
    # length bytes, not by matching text, is what makes this hold for every
    # RPC name: the old check matched the refusal only when its length byte
    # happened to be absent or "E".
    def read_response
      raw = read_until_eot_raw.to_s
      sec, err, data = snderr_split(raw)
      return raw if data.nil? # not SNDERR-framed (e.g. a stand-in reply)

      raise Client.rpc_error_for(sec), RpmsRpc.sanitize_error(sec) unless sec.empty?
      raise Client.rpc_error_for(err), RpmsRpc.sanitize_error(err) unless err.empty?

      data
    end

    # [security text, application text, data], or nil when the bytes cannot
    # be the SNDERR header.
    def snderr_split(raw)
      bytes = raw.b
      return nil if bytes.bytesize < 2

      sec_len = bytes.getbyte(0)
      err_at = 1 + sec_len
      return nil if err_at >= bytes.bytesize

      err_len = bytes.getbyte(err_at)
      data_at = err_at + 1 + err_len
      return nil if data_at > bytes.bytesize

      [ bytes.byteslice(1, sec_len), bytes.byteslice(err_at + 1, err_len), raw.byteslice(data_at..) ]
    end
  end
end
