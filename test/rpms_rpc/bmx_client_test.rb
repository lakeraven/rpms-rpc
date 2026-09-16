# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/bmx_client"

class RpmsRpc::BmxClientTest < Minitest::Test
  Client = RpmsRpc::BmxClient

  def setup
    @prev_port = ENV["VISTA_RPC_PORT"]
    ENV.delete("VISTA_RPC_PORT")
  end

  def teardown
    ENV["VISTA_RPC_PORT"] = @prev_port
  end

  def test_inherits_from_client
    assert Client < RpmsRpc::Client
  end

  def test_default_port_is_9200
    assert_equal 9200, Client.new.port
  end

  def test_bmx_prefix
    assert_equal "{BMX}", Client::BMX_PREFIX
  end

  # -- build_bmx_message ------------------------------------------------------

  def test_build_bmx_message_includes_proto_header_and_msg_header
    msg = Client.new.build_bmx_message("ECHO^hello")
    # Proto header: "015" + "RPMS_RPC;0;0;0;" (15 chars)
    assert msg.start_with?("015RPMS_RPC;0;0;0;^")
    # Message header: "%05d;1" where %05d = body.length + 6
    # body = "ECHO^hello" (10 chars) → 10 + 6 = 16 → "00016;1"
    assert_includes msg, "00016;1ECHO^hello"
  end

  def test_build_bmx_message_with_empty_params
    msg = Client.new.build_bmx_message("XUS SIGNON SETUP")
    # body = "XUS SIGNON SETUP" (16 chars) → 16 + 6 = 22 → "00022;1"
    assert_includes msg, "00022;1XUS SIGNON SETUP"
  end

  # -- byte-safety (multibyte / binary) --------------------------------------

  def test_build_bmx_message_is_binary_encoded
    msg = Client.new.build_bmx_message("ECHO^hello")
    assert_equal Encoding::ASCII_8BIT, msg.encoding
  end

  def test_build_bmx_message_uses_bytesize_for_multibyte_input
    # body = "ECHO^héllo" = 4 + 1 + 5(héllo, where é=2) = 11 bytes (not 10 chars)
    msg = Client.new.build_bmx_message("ECHO^héllo")
    assert msg.start_with?("015RPMS_RPC;0;0;0;^".b)
    # body bytesize 11 + 6 = 17 → "00017;1"
    assert_includes msg, "00017;1ECHO^héllo".b
  end

  # -- subclass contract ------------------------------------------------------

  def test_call_rpc_raises_when_not_connected
    assert_raises(RpmsRpc::Client::ConnectionError) { Client.new.call_rpc("XUS SIGNON SETUP") }
  end

  def test_call_rpc_raw_raises_when_not_connected
    assert_raises(RpmsRpc::Client::ConnectionError) { Client.new.call_rpc_raw("XUS SIGNON SETUP") }
  end

  # -- list-param rejection (BMX wire format doesn't support multi-line) -----

  def test_call_rpc_rejects_array_param_with_clear_error
    client = Client.new
    # Bypass not-connected check by stubbing connected?
    client.define_singleton_method(:connected?) { true }
    error = assert_raises(NotImplementedError) do
      client.call_rpc("BEHOVM SAVE", "8791", [ "HDR^^^v1", "VST^DT^now" ])
    end
    assert_match(/BMX client does not yet support list/i, error.message)
    assert_match(/BEHOVM SAVE/, error.message)
  end

  def test_call_rpc_rejects_hash_param_with_clear_error
    client = Client.new
    client.define_singleton_method(:connected?) { true }
    error = assert_raises(NotImplementedError) do
      client.call_rpc("SOME RPC", "scalar", { a: 1 })
    end
    assert_match(/BMX client does not yet support/i, error.message)
  end

  # -- "^" cannot cross the BMX wire inside a parameter ----------------------
  #
  # PRSA^BMXMBRK (BMXMBRK.m:69-70) takes everything after the FIRST "^" of
  # the content line as the parameter string — the caret is STRUCTURAL and
  # the protocol has no escape for it. A scalar containing "^" is therefore
  # indistinguishable on the wire from extra parameters: XUS CVC's payload
  # (three ciphertexts joined with "^", which CVC^XUSRB itself splits) would
  # silently split and the RPC would run on a fragment. Fail loud instead.

  class RecordingSocket
    attr_reader :writes

    def initialize(reads = [])
      @reads = reads.dup
      @writes = []
    end

    def write(str) = (@writes << str) && str.bytesize
    def recv(_n) = @reads.empty? ? "" : @reads.shift
    def flush; end
    def close = @closed = true
    def closed? = !!@closed
    def setsockopt(*); end
  end

  def connected_client(reads = [])
    c = Client.new
    c.instance_variable_set(:@socket, RecordingSocket.new(reads))
    c.instance_variable_set(:@connected, true)
    c.instance_variable_set(:@timeout, 1)
    c
  end

  def test_a_caret_bearing_param_is_rejected_before_it_reaches_the_wire
    client = connected_client
    error = assert_raises(NotImplementedError,
      "a '^'-bearing param must fail LOUD — the wire would silently split it") do
      client.call_rpc_raw("XUS CVC", "encA^encB^encC")
    end
    assert_match(/\^/, error.message)
    assert_empty client.instance_variable_get(:@socket).writes,
      "the split frame reached the wire"
  end

  # The facade path: change_verify_code's payload is BY DESIGN a "^"-joined
  # triple (CVC^XUSRB splits it server-side), so on BMX it must raise the
  # typed transport limitation — never write a frame the broker would read
  # as three separate parameters, and never dress the wreckage up as a
  # generic failure.
  def test_change_verify_code_over_bmx_raises_the_transport_limitation
    require "rpms_rpc/api/authentication"
    client = connected_client([ "\x00\x00" ]) # never reached
    RpmsRpc.configure { |c| c.client = client }

    assert_raises(NotImplementedError) do
      RpmsRpc::Authentication.change_verify_code(
        old_verify_code: "OLD1!", new_verify_code: "NEW2!", confirm_verify_code: "NEW2!"
      )
    end
    assert_empty client.instance_variable_get(:@socket).writes
  ensure
    RpmsRpc.reset!
  end

  # WIRE-LEVEL regression for the sign-on path: the encoded frame — not the
  # pre-serialization argument list — must carry the encrypted AV pair as
  # exactly ONE parameter, and that parameter must decrypt back to the pair.
  # (XwbCipher's table is the 95 printables minus "^" in every row, and its
  # framing bytes are chr(32..51), so ciphertext of a caret-free pair can
  # never contain the joiner — asserted as a gate in xwb_cipher_test.)
  def test_the_encrypted_av_pair_crosses_the_bmx_wire_as_one_parameter
    client = connected_client([
      "\x00\x00OK\x04",                    # XUS SIGNON SETUP
      "\x00\x00301\r\n0\r\n0\r\nHi\x04"    # XUS AV CODE
    ])

    result = client.authenticate("AC123", "VC123!")
    assert result[:success]

    av_frame = client.instance_variable_get(:@socket).writes.last
    content = av_frame[/;1(.+)\z/m, 1]
    pieces = content.split("^", -1)
    assert_equal 2, pieces.length,
      "the AV ciphertext split into multiple BMX parameters on the wire: #{pieces.inspect}"
    assert_equal "XUS AV CODE", pieces[0]
    assert_equal "AC123;VC123!", RpmsRpc::XwbCipher.decrypt(pieces[1]),
      "the single wire parameter does not decrypt back to the AV pair"
  end
end
