# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "openssl"
require "socket"
require "timeout"
require "tmpdir"
require "rpms_rpc/cia_client"

# The sample stunnel configs in docs/tls/ are validated, not just shown (#113).
#
# Both shipped samples run as written: only file paths, ports and the connect
# host are substituted. Every TLS option in them (client mode, mutual
# certificates, verifyChain, checkHost, the TLS floor) stays exactly as an
# operator would copy it. Through them:
#
#   CiaClient -> app-side stunnel -> TLS -> RPMS-side stunnel -> fake CIA broker
#
# CI installs stunnel; elsewhere the test skips when stunnel is absent.
class RpmsRpc::StunnelSampleTest < Minitest::Test
  DOCS = File.expand_path("../../docs/tls", __dir__)
  APP_SIDE = File.join(DOCS, "stunnel-app-side.conf")
  RPMS_SIDE = File.join(DOCS, "stunnel-rpms-side.conf")
  # The broker's name in the samples; the RPMS-side certificate is issued to it
  # and the app side's checkHost requires it.
  RPMS_HOST = "rpms.example.internal"
  EOD = RpmsRpc::Client::EOD

  def self.stunnel_binary
    %w[stunnel4 stunnel].each do |name|
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, name)
        return path if File.file?(path) && File.executable?(path)
      end
    end
    nil
  end

  def setup
    @stunnel = self.class.stunnel_binary
    skip "stunnel is not installed (CI installs it; brew/apt install stunnel to run locally)" unless @stunnel

    @dir = Dir.mktmpdir("rpms-rpc-stunnel")
    @pids = []
    write_pki
    @broker = FakeCiaBroker.new
    @tls_port = free_port
    @app_port = free_port
    start_stunnel("rpms-side", RPMS_SIDE,
                  accept: "0.0.0.0:#{@tls_port}", connect: "127.0.0.1:#{@broker.port}",
                  cert: "rpms.crt", key: "rpms.key", ca: "ca.crt")
    start_stunnel("app-side", APP_SIDE,
                  accept: "127.0.0.1:#{@app_port}", connect: "127.0.0.1:#{@tls_port}",
                  cert: "app.crt", key: "app.key", ca: "ca.crt")
    wait_for_port(@tls_port)
    wait_for_port(@app_port)
  end

  def teardown
    @pids&.each { |pid| stop(pid) }
    @broker&.close
    FileUtils.rm_rf(@dir) if @dir
  end

  def test_cia_client_frames_cross_the_sample_tunnel
    client = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: @app_port, timeout: 5)
    client.connect
    assert client.connected?, "the {CIA} connect handshake must cross the tunnel"

    reply = client.call_rpc_raw("XWB IM HERE")
    assert_equal "2\x00ok".b, reply.b, "an RPC reply must come back through the tunnel"
    assert(@broker.frames.all? { |f| f.start_with?("{CIA}") },
           "the broker must receive the client's frames in plaintext, unchanged")
    assert_equal 2, @broker.frames.size
  ensure
    client&.disconnect
  end

  def test_the_tls_port_refuses_a_plaintext_client
    frames_before = @broker.frames.size
    sock = TCPSocket.new("127.0.0.1", @tls_port)
    sock.write("{CIA}#{EOD}1C#{EOD}")
    reply = read_until_closed(sock)
    refute_includes reply.to_s, "1^1", "a plaintext frame must not reach the broker"
    assert_equal frames_before, @broker.frames.size
  ensure
    sock&.close
  end

  def test_the_tls_port_refuses_a_client_without_a_certificate
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.ca_file = path("ca.crt")
    ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
    tcp = TCPSocket.new("127.0.0.1", @tls_port)
    ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
    ssl.hostname = RPMS_HOST
    refused = Timeout.timeout(10) do
      ssl.connect
      ssl.write("{CIA}#{EOD}1C#{EOD}")
      ssl.sysread(1)
      false
    rescue OpenSSL::SSL::SSLError, EOFError, Errno::ECONNRESET, Errno::EPIPE
      true # TLS 1.3 reports the missing certificate on the first read
    end
    assert refused, "the RPMS side must require a client certificate (mutual TLS)"
    assert_empty @broker.frames, "an unauthenticated peer's frame must not reach the broker"
  ensure
    ssl&.close
    tcp&.close
  end

  private

  def path(name) = File.join(@dir, name)

  # Run a shipped sample with only paths, ports and the connect host replaced.
  def start_stunnel(name, sample, accept:, connect:, cert:, key:, ca:)
    conf = File.read(sample)
    {
      "accept" => accept, "connect" => connect,
      "cert" => path(cert), "key" => path(key), "CAfile" => path(ca)
    }.each do |option, value|
      pattern = /^(\s*#{option}\s*=\s*).*$/
      assert_match pattern, conf, "#{File.basename(sample)} must set #{option}"
      conf = conf.sub(pattern) { "#{Regexp.last_match(1)}#{value}" }
    end
    # Global options for a test process: stay in the foreground, no pid file.
    conf = "foreground = yes\npid =\noutput = #{path("#{name}.log")}\n#{conf}"
    File.write(path("#{name}.conf"), conf)
    @pids << Process.spawn(@stunnel, path("#{name}.conf"), out: File::NULL, err: File::NULL)
  end

  # stunnel exits on TERM, but not always promptly while it holds a connection
  # whose far end is gone; never let teardown hang on it.
  def stop(pid)
    Process.kill("TERM", pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    until Process.wait(pid, Process::WNOHANG)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Process.kill("KILL", pid)
        Process.wait(pid)
        break
      end
      sleep 0.05
    end
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def wait_for_port(port)
    Timeout.timeout(10) do
      loop do
        TCPSocket.new("127.0.0.1", port).close
        break
      rescue Errno::ECONNREFUSED
        sleep 0.05
      end
    end
  rescue Timeout::Error
    logs = Dir[path("*.log")].map { |f| "#{File.basename(f)}:\n#{File.read(f)}" }.join("\n")
    flunk "stunnel did not open port #{port}:\n#{logs}"
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def read_until_closed(sock)
    out = +""
    Timeout.timeout(5) do
      loop { out << sock.readpartial(4096) }
    end
  rescue EOFError, Errno::ECONNRESET
    out
  end

  # A throwaway CA, an RPMS-side certificate issued to RPMS_HOST, and an
  # app-side client certificate.
  def write_pki
    ca_key = OpenSSL::PKey::RSA.new(2048)
    ca = certificate("CN=rpms-rpc test CA", ca_key, ca_key, nil, ca: true)
    File.write(path("ca.crt"), ca.to_pem)
    { "rpms" => RPMS_HOST, "app" => "rpms-rpc app" }.each do |name, cn|
      key = OpenSSL::PKey::RSA.new(2048)
      cert = certificate("CN=#{cn}", key, ca_key, ca, san: (cn == RPMS_HOST ? "DNS:#{RPMS_HOST}" : nil))
      File.write(path("#{name}.crt"), cert.to_pem)
      File.write(path("#{name}.key"), key.to_pem)
      File.chmod(0o600, path("#{name}.key"))
    end
  end

  def certificate(subject, key, signing_key, issuer, ca: false, san: nil)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = rand(1..2**31)
    cert.subject = OpenSSL::X509::Name.parse(subject)
    cert.issuer = issuer ? issuer.subject : cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    ext = OpenSSL::X509::ExtensionFactory.new
    ext.subject_certificate = cert
    ext.issuer_certificate = issuer || cert
    cert.add_extension(ext.create_extension("basicConstraints", ca ? "CA:TRUE" : "CA:FALSE", true))
    cert.add_extension(ext.create_extension("keyUsage", ca ? "keyCertSign,cRLSign" : "digitalSignature,keyEncipherment", true))
    cert.add_extension(ext.create_extension("subjectAltName", san)) if san
    cert.sign(signing_key, OpenSSL::Digest.new("SHA256"))
    cert
  end

  # Answers the {CIA} connect handshake and one RPC per connection, recording
  # every frame it receives. A frame is "{CIA}" EOD seq action fields EOD.
  class FakeCiaBroker
    attr_reader :frames, :port

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @frames = []
      @thread = Thread.new { serve }
    end

    def close
      @server.close
      @thread.kill
    end

    private

    def serve
      loop do
        conn = @server.accept
        Thread.new(conn) { |c| session(c) }
      end
    rescue IOError
      nil
    end

    def session(conn)
      buf = "".b
      loop do
        buf << conn.readpartial(4096).b
        while (frame = take_frame(buf))
          @frames << frame
          seq = frame[6]
          body = frame[7] == "C" ? "1^1^1.1^^1" : "ok"
          conn.write("#{seq}\x00#{body}#{EOD}".b)
        end
      end
    rescue EOFError, IOError, Errno::ECONNRESET
      conn.close
    end

    # A frame's first EOD is header byte 6; it ends at the next EOD after the
    # 8-byte header. (Field values here never contain the EOD byte.)
    def take_frame(buf)
      return nil unless buf.bytesize >= 9

      stop = buf.index(EOD.b, 8)
      return nil unless stop

      buf.slice!(0..stop)
    end
  end
end
