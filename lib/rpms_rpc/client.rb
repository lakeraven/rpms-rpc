# frozen_string_literal: true

require "socket"
require "rpms_rpc/parameter_encoder"
require "rpms_rpc/xml_response_parser"

module RpmsRpc
  # Abstract base class for RPMS RPC broker clients.
  #
  # Subclass this for protocol-specific clients (RpmsRpc::CiaClient,
  # RpmsRpc::BmxClient). Provides connection lifecycle, authentication,
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
    # Error classes
    class ConnectionError < StandardError; end
    class AuthenticationError < StandardError; end
    class RpcError < StandardError; end
    class TimeoutError < ConnectionError; end

    # Shared constants
    EOT = "\x04"
    RECV_SIZE = 4096
    DEFAULT_TIMEOUT = 30 # seconds

    # Traditional VistA/Kernel cipher table (from XUSRB1.m)
    CIPHER_TABLE = [
      'wkEo-ZJt!dG)49K{nX1BS$vH<&:Myf*>Ae0jQW=;|#PsO`\'%+rmb[gpqN,l6/hFC@DcUa ]z~R}"V\\iIxu?872.(TYL5_3',
      'rKv`R;M/9BqAF%&tSs#Vh)dO1DZP> *fX\'u[.4lY=-mg_ci802N7LTG<]!CWo:3?{+,5Q}(@jaExn$~p\\IyHwzU"|k6Jeb',
      '\\pV(ZJk"WQmCn!Y,y@1d+~8s?[lNMxgHEt=uw|X:qSLjAI*}6zoF{T3#;ca)/h5%`P4$r]G\'9e2if_>UDKb7<v0&- RBO.',
      'depjt3g4W)qD0V~NJar\\B "?OYhcu[<Ms%Z`RIL_6:]AX-zG.#}$@vk7/5x&*m;(yb2Fn+l\'PwUof1K{9,|EQi>H=CT8S!',
      'NZW:1}K$byP;jk)7\'`x90B|cq@iSsEnu,(l-hf.&Y_?J#R]+voQXU8mrV[!p4tg~OMez CAaGFD6H53%L/dT2<*>"{\\wI=',
      'vCiJ<oZ9|phXVNn)m K`t/SI%]A5qOWe\\&?;jT~M!fz1l>[D_0xR32c*4.P"G{r7}E8wUgyudF+6-:B=$(sY,LkbHa#\'@Q',
      'hvMX,\'4Ty;[a8/{6l~F_V"}qLI\\!@x(D7bRmUH]W15J%N0BYPkrs&9:$)Zj>u|zwQ=ieC-oGA.#?tfdcO3gp`S+En K2*<',
      'jd!W5[];4\'<C$/&x|rZ(k{>?ghBzIFN}fAK"#`p_TqtD*1E37XGVs@0nmSe+Y6Qyo-aUu%i8c=H2vJ\\) R:MLb.9,wlO~P',
      '2ThtjEM+!=xXb)7,ZV{*ci3"8@_l-HS69L>]\\AUF/Q%:qD?1~m(yvO0e\'<#o$p4dnIzKP|`NrkaGg.ufCRB[; sJYwW}5&',
      'vB\\5/zl-9y:Pj|=(R\'7QJI *&CTX"p0]_3.idcuOefVU#omwNZ`$Fs?L+1Sk<,b)hM4A6[Y%aDrg@~KqEW8t>H};n!2xG{',
      'sFz0Bo@_HfnK>LR}qWXV+D6`Y28=4Cm~G/7-5A\\b9!a#rP.l&M$hc3ijQk;),TvUd<[:I"u1\'NZSOw]*gxtE{eJp|y (?%',
      'M@,D}|LJyGO8`$*ZqH .j>c~h<d=fimszv[#-53F!+a;NC\'6T91IV?(0x&/{B)w"]Q\\YUWprk4:ol%g2nE7teRKbAPuS_X',
      '.mjY#_0*H<B=Q+FML6]s;r2:e8R}[ic&KA 1w{)vV5d,$u"~xD/Pg?IyfthO@CzWp%!`N4Z\'3-(o|J9XUE7k\\TlqSb>anG',
      'xVa1\']_GU<X`|\\NgM?LS9{"jT%s$}y[nvtlefB2RKJW~(/cIDCPow4,>#zm+:5b@06O3Ap8=*7ZFY!H-uEQk; .q)i&rhd',
      'I]Jz7AG@QX."%3Lq>METUo{Pp_ |a6<0dYVSv8:b)~W9NK`(r\'4fs&wim\\kReC2hg=HOj$1B*/nxt,;c#y+![?lFuZ-5D}',
      'Rr(Ge6F Hx>q$m&C%M~Tn,:"o\'tX/*yP.{lZ!YkiVhuw_<KE5a[;}W0gjsz3]@7cI2\\QN?f#4p|vb1OUBD9)=-LJA+d`S8',
      'I~k>y|m};d)-7DZ"Fe/Y<B:xwojR,Vh]O0Sc[`$sg8GXE!1&Qrzp._W%TNK(=J 3i*2abuHA4C\'?Mv\\Pq{n#56LftUl@9+',
      '~A*>9 WidFN,1KsmwQ)GJM{I4:C%}#Ep(?HB/r;t.&U8o|l[\'Lg"2hRDyZ5`nbf]qjc0!zS-TkYO<_=76a\\X@$Pe3+xVvu',
      'yYgjf"5VdHc#uA,W1i+v\'6|@pr{n;DJ!8(btPGaQM.LT3oe?NB/&9>Z`-}02*%x<7lsqz4OS ~E$\\R]KI[:UwC_=h)kXmF',
      '5:iar.{YU7mBZR@-K|2 "+~`M%8sq4JhPo<_X\\Sg3WC;Tuxz,fvEQ1p9=w}FAI&j/keD0c?)LN6OHV]lGy\'$*>nd[(tb!#'
    ].freeze

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

      ac = access_code || ENV.fetch("RPMS_ACCESS_CODE", "PROV123")
      vc = verify_code || ENV.fetch("RPMS_VERIFY_CODE", "PROV123!!")

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
        raise AuthenticationError, (err_msg.nil? || err_msg.empty? ? "Authentication failed" : err_msg)
      end

      @authenticated = true
      @duz = duz_str
      { success: true, duz: duz_str.to_i }
    end

    # Set application context (required before calling most RPCs)
    def create_context(option_name = "OR CPRS GUI CHART")
      raise ConnectionError, "Not connected" unless connected?
      raise AuthenticationError, "Not authenticated" unless authenticated?

      encrypted = xwb_encrypt(option_name)
      reply = call_rpc_raw("XWB CREATE CONTEXT", encrypted)

      unless reply&.strip == "1"
        raise RpcError, "Failed to create context '#{option_name}': #{reply}"
      end

      true
    end

    # XWB cipher encryption (matches $$ENCRYP^XUSRB1 in M)
    def xwb_encrypt(plaintext)
      ra = rand(0..19)
      rb = rand(1..19)
      rb = rand(1..19) while rb == ra
      row_a = CIPHER_TABLE[ra]
      row_b = CIPHER_TABLE[rb]
      result = (ra + 32).chr
      plaintext.each_char do |ch|
        idx = row_a.index(ch)
        result += idx.nil? ? ch : row_b[idx]
      end
      result += (rb + 32).chr
      result
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
    end

    # Open a TCP socket to the broker
    def open_socket(host, port)
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

    # Read from socket until EOT (\x04), with timeout via IO.select
    def read_until_eot_raw
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
          raise ConnectionError, "Connection closed by server"
        end
        if chunk.include?(EOT)
          idx = chunk.index(EOT)
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

    # Check for M errors returned as data (not via SNDERR)
    def check_for_rpc_error(response)
      return if response.nil? || response.empty?

      clean = response.strip.gsub(/\x00+$/, "")
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
