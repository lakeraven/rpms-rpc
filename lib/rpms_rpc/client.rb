# frozen_string_literal: true

require "socket"
require "rpms_rpc/parameter_encoder"
require "rpms_rpc/xml_response_parser"
require "rpms_rpc/server_capabilities"
require "rpms_rpc/xwb_cipher"
require "rpms_rpc/context_scope"

module RpmsRpc
  # Abstract base class for RPMS RPC broker clients.
  #
  # Subclass this for protocol-specific clients (RpmsRpc::XwbClient,
  # RpmsRpc::CiaClient, RpmsRpc::BmxClient). Provides connection lifecycle, authentication,
  # cipher encryption, and response parsing helpers. Each subclass
  # implements its own wire protocol.
  #
  # Subclass contract (must define):
  #   connect(host, port)         — open socket and perform protocol handshake
  #   disconnect                  — send shutdown command and close socket
  #   call_rpc(name, *params)     — encode, send, read, and parse one RPC call
  #   call_rpc_raw(name, *params) — send RPC, return raw string response
  #   read_response               — read and decode one protocol response
  class Client
    # current_context / with_context — RPC registration is OPTION-scoped, so
    # an API whose RPCs live under their own option scopes itself to it.
    include ContextScope

    # Error classes
    class ConnectionError < StandardError; end
    class AuthenticationError < StandardError; end
    # Raised when RPMS credentials are missing or set to the dev-only
    # PROV123/PROV123!! defaults outside a development environment.
    # Subclass of AuthenticationError so existing rescue blocks keep
    # working, but callers can distinguish "credential misconfigured"
    # from "credential rejected by broker".
    class CredentialError < AuthenticationError; end
    class RpcError < StandardError; end
    class TimeoutError < ConnectionError; end
    # Raised when a single RPC's reply times out mid-call. Subclass of
    # TimeoutError (and so ConnectionError) so existing rescue blocks keep
    # working, but distinct so callers can tell "this one RPC hung" from a
    # dead broker. The client closes the socket first — a reply abandoned
    # mid-read cannot be resynchronized — so callers may reconnect and
    # re-authenticate rather than retrying on a corrupted stream.
    class RpcTimeoutError < TimeoutError; end

    # Shared constants
    EOT = "\x04"        # frame terminator for XWB ([XWB]1130) and BMX ({BMX})
    EOD = "\x1e"        # frame terminator for CIA ({CIA}, CIANBLIS)
    RECV_SIZE = 4096
    DEFAULT_TIMEOUT = 30 # seconds

    # Traditional VistA/Kernel cipher table (from XUSRB1.m) — lives in
    # RpmsRpc::XwbCipher so non-Client code (e.g. the ESignature API) can
    # encrypt too; kept aliased here for backward compatibility.
    CIPHER_TABLE = XwbCipher::TABLE

    attr_reader :host, :port, :connected, :timeout

    def initialize(host: nil, port: nil, timeout: nil)
      @host = host || ENV.fetch("VISTA_RPC_HOST", "localhost")
      @port = (port || ENV.fetch("VISTA_RPC_PORT", default_port.to_s)).to_i
      @timeout = (timeout || ENV.fetch("VISTA_RPC_TIMEOUT", DEFAULT_TIMEOUT.to_s)).to_i
      @socket = nil
      @connected = false
      @authenticated = false
      @duz = nil
    end

    # -- subclass contract ----------------------------------------------------

    def connect(_host, _port)
      raise NotImplementedError, "#{self.class} must implement #connect"
    end

    def disconnect
      raise NotImplementedError, "#{self.class} must implement #disconnect"
    end

    def call_rpc(_name, *_params)
      raise NotImplementedError, "#{self.class} must implement #call_rpc"
    end

    def call_rpc_raw(_name, *_params)
      raise NotImplementedError, "#{self.class} must implement #call_rpc_raw"
    end

    def read_response
      raise NotImplementedError, "#{self.class} must implement #read_response"
    end

    # -- connection state -----------------------------------------------------

    # True only when the handshake completed AND the socket is still open.
    # Both the @connected flag (set after handshake / cleared on error) and
    # the live socket state must agree, so error/timeout paths can't leave
    # the object reporting connected with a half-dead socket.
    def connected?
      return false unless @connected
      return false unless @socket
      return false if @socket.closed?
      true
    end

    def hostname
      @host
    end

    def authenticated?
      @authenticated
    end

    def set_authenticated(duz)
      @authenticated = true
      @duz = duz
    end

    def duz
      @duz
    end

    # -- VistA signon ---------------------------------------------------------

    # Run XUS SIGNON SETUP (returns environment data array)
    def signon_setup
      raise ConnectionError, "Not connected" unless connected?

      call_rpc("XUS SIGNON SETUP")
    end

    # Authenticate with VistA using Access/Verify codes.
    # Returns { success: true, duz: } hash or raises AuthenticationError.
    def authenticate(access_code = nil, verify_code = nil, **)
      raise ConnectionError, "Not connected" unless connected?

      ac, vc = resolve_credentials(access_code, verify_code)

      # Step 1: XUS SIGNON SETUP
      signon_setup

      # Step 2: XUS AV CODE with encrypted credentials
      av_encrypted = xwb_encrypt("#{ac};#{vc}")
      reply = call_rpc_raw("XUS AV CODE", av_encrypted)

      lines = reply.split("\r\n")
      lines = reply.split("\n") if lines.length <= 1
      duz_str = lines[0]&.strip || "0"

      if duz_str == "0" || duz_str.empty?
        err_msg = lines[3]&.strip if lines.length > 3
        raise AuthenticationError, RpmsRpc.sanitize_error(
          err_msg.nil? || err_msg.empty? ? "Authentication failed" : err_msg
        )
      end

      @authenticated = true
      @duz = duz_str
      { success: true, duz: duz_str.to_i }
    end

    # Whether the Broker behind this client can service `feature`.
    #
    # First call per feature probes the underlying RPCs via
    # ServerCapabilities; subsequent calls return the cached result.
    # Engine code should consult this before issuing the underlying calls
    # so that "feature unavailable" returns nil/empty without a wasted
    # Broker round-trip.
    def supports?(feature)
      @capability_cache ||= {}
      return @capability_cache[feature] if @capability_cache.key?(feature)

      @capability_cache[feature] = ServerCapabilities.probe(self, feature)
    end

    # Set application context (required before calling most RPCs)
    def create_context(option_name = "OR CPRS GUI CHART")
      raise ConnectionError, "Not connected" unless connected?
      raise AuthenticationError, "Not authenticated" unless authenticated?

      encrypted = xwb_encrypt(option_name)
      reply = call_rpc_raw("XWB CREATE CONTEXT", encrypted)

      unless reply&.strip == "1"
        raise RpcError, RpmsRpc.sanitize_error(
          "Failed to create context '#{option_name}': #{reply}"
        )
      end

      # RPC registration is OPTION-scoped; capabilities probed under the
      # previous context may not hold under the new one.
      @capability_cache = nil
      @current_context = option_name # ContextScope — lets APIs scope + restore
      true
    end

    # -- credential resolution ------------------------------------------------

    DEV_DEFAULT_ACCESS = "PROV123"
    DEV_DEFAULT_VERIFY = "PROV123!!"
    private_constant :DEV_DEFAULT_ACCESS, :DEV_DEFAULT_VERIFY

    # Resolve the access / verify pair from (in order) explicit args,
    # then ENV. In a non-development environment, refuses to fall through
    # to the DEV_DEFAULT_* values — raises CredentialError so a
    # misconfigured deploy can't silently talk to the broker as a debug
    # account.
    #
    # Development detection: `Rails.env == "development"` if Rails is
    # loaded; otherwise `ENV["VISTA_RPC_ENV"] == "development"`. Anything
    # unset is treated as production for strict-by-default safety.
    def resolve_credentials(access_code, verify_code)
      ac = access_code || ENV["RPMS_ACCESS_CODE"]
      vc = verify_code || ENV["RPMS_VERIFY_CODE"]

      if development_environment?
        ac ||= DEV_DEFAULT_ACCESS
        vc ||= DEV_DEFAULT_VERIFY
        return [ ac, vc ]
      end

      # Blank strings (empty / whitespace-only) are just as broken as
      # unset credentials. Don't let an empty ENV value bypass the check.
      if blank_credential?(ac) || blank_credential?(vc)
        raise CredentialError,
              "RPMS credentials not configured. Set RPMS_ACCESS_CODE and " \
              "RPMS_VERIFY_CODE in the environment (or pass explicit args " \
              "to #authenticate) — production deploys must not rely on " \
              "the development PROV123 fallback."
      end

      # Reject if EITHER value equals its dev default — a half-copied
      # config (one real value, one PROV123 placeholder) is just as
      # broken as the all-defaults case.
      if ac == DEV_DEFAULT_ACCESS || vc == DEV_DEFAULT_VERIFY
        raise CredentialError,
              "RPMS credentials include the development PROV123 / " \
              "PROV123!! default value. Refusing to authenticate against " \
              "a production broker with any debug credential."
      end

      [ ac, vc ]
    end

    def development_environment?
      if defined?(Rails) && Rails.respond_to?(:env) && Rails.env
        Rails.env.development?
      else
        ENV["VISTA_RPC_ENV"] == "development"
      end
    end
    private :development_environment?

    def blank_credential?(value)
      value.nil? || value.to_s.strip.empty?
    end
    private :blank_credential?

    # XWB cipher encryption (matches $$ENCRYP^XUSRB1 in M)
    def xwb_encrypt(plaintext)
      XwbCipher.encrypt(plaintext)
    end

    # -- encoding / parsing helpers -------------------------------------------

    # Encode a single parameter using ParameterEncoder
    def encode_param(param)
      ParameterEncoder.encode(param)
    end
    alias_method :encode_parameter, :encode_param

    # Parse RPC response using XmlResponseParser when XML, else pass through
    def parse_rpc_response(response)
      return [] if response.nil? || response.empty? || (response.is_a?(String) && response.strip.empty?)

      if response.is_a?(String) && response.strip.start_with?("<")
        begin
          XmlResponseParser.parse(response)
        rescue XmlResponseParser::ParseError => e
          raise RpcError, "Failed to parse RPC response: #{e.message}"
        rescue XmlResponseParser::RpcError => e
          raise RpcError, e.message
        end
      else
        response
      end
    end

    # Read until EOT marker (compatibility alias)
    def read_until_eot
      read_response
    end

    # Get local IP address
    def local_ip
      Socket.ip_address_list.find { |ai| ai.ipv4? && !ai.ipv4_loopback? }&.ip_address || "127.0.0.1"
    end

    private

    # Default port — overridden by subclasses
    def default_port
      9100
    end

    # Close socket and reset state
    def reset_connection
      @socket&.close
      @socket = nil
      @connected = false
      @authenticated = false
      @duz = nil
      @capability_cache = nil
    end

    # Open a TCP socket to the broker
    def open_socket(host, port)
      # Implicit reconnects (after a send/recv error path that only set
      # @connected = false) re-enter here without going through
      # reset_connection. Clear the capability cache so a reconnect to
      # the same or a different Broker can never inherit stale answers.
      @capability_cache = nil
      @host = host
      @port = port
      @socket = TCPSocket.new(host, port)
      @socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EHOSTUNREACH, Socket::ResolutionError => e
      @connected = false
      raise ConnectionError, "Failed to connect to #{host}:#{port} - #{e.message}"
    end

    # Send raw bytes to the broker
    def send_packet(packet)
      @socket.write(packet)
      @socket.flush
    rescue IOError => e
      @connected = false
      raise ConnectionError, "Connection lost - stream closed: #{e.message}"
    rescue Errno::ECONNRESET
      @connected = false
      raise ConnectionError, "Connection lost - reset by server"
    rescue Errno::EPIPE
      @connected = false
      raise ConnectionError, "Connection lost - broken pipe"
    rescue Errno::ENOTCONN
      @connected = false
      raise ConnectionError, "Connection lost - socket not connected"
    rescue SocketError => e
      @connected = false
      raise ConnectionError, "Connection lost - network error: #{e.message}"
    end

    # Back-compat alias for the XWB/BMX path (terminator EOT).
    def read_until_eot_raw = read_until_raw(EOT)

    # Read from socket until `terminator`, with timeout via IO.select. Terminator is
    # protocol-specific: XWB/BMX use EOT (\x04), CIA uses EOD (\x1e). Shared by all clients.
    def read_until_raw(terminator = EOT)
      return "" unless @socket

      chunks = []
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if remaining <= 0
          @connected = false
          raise TimeoutError, "RPC read timed out after #{@timeout}s"
        end

        if @socket.is_a?(BasicSocket) || @socket.is_a?(IO)
          begin
            unless IO.select([ @socket ], nil, nil, remaining)
              @connected = false
              raise TimeoutError, "RPC read timed out after #{@timeout}s"
            end
          rescue TypeError
            # StringIO or other non-selectable IO in tests — skip select
          end
        end

        chunk = @socket.recv(RECV_SIZE)
        if chunk.nil? || chunk.empty?
          @connected = false
          raise ConnectionError, "Connection closed by server"
        end
        if chunk.include?(terminator)
          idx = chunk.index(terminator)
          chunks << chunk[0...idx]
          break
        end
        chunks << chunk
      end

      chunks.join
    rescue IO::TimeoutError => e
      raise ConnectionError, "Connection timeout: #{e.message}"
    rescue IOError => e
      @connected = false
      raise ConnectionError, "Connection lost - stream closed: #{e.message}"
    rescue Errno::ECONNRESET
      @connected = false
      raise ConnectionError, "Connection lost - reset by server"
    rescue Errno::EPIPE
      @connected = false
      raise ConnectionError, "Connection lost - broken pipe"
    rescue Errno::ENOTCONN
      @connected = false
      raise ConnectionError, "Connection lost - socket not connected"
    rescue SocketError => e
      @connected = false
      raise ConnectionError, "Connection lost - network error: #{e.message}"
    end

    # Check for M errors returned as data (not via SNDERR).
    #
    # Some Brokers prefix error payloads with \x18 (CAN, wire-level error
    # sentinel) before the "M  ERROR=" frame. String#strip does not remove
    # \x18, so anchor-matching on the raw response misses these — peel the
    # sentinel before the regex.
    def check_for_rpc_error(response)
      return if response.nil? || response.empty?

      clean = response.sub(/\A\x18/, "").strip.gsub(/\x00+$/, "")
      if clean.match?(/\A(?:M  ERROR|E?Remote Procedure '.*' doesn't exist|E?Remote Procedure '.*' not found)/i)
        raise RpcError, clean
      end
    end

    # Split response string into array of lines (gateway convention)
    def split_response(response)
      response.chomp!("\r\n")
      response.chomp!("\n")
      if response.include?("\r\n")
        response.split("\r\n", -1)
      elsif response.include?("\n")
        response.split("\n", -1)
      else
        response.empty? ? [] : [ response ]
      end
    end
  end
end
