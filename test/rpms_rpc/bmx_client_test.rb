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

  def test_default_port_is_9101
    assert_equal 9101, Client.new.port
  end

  def test_bmx_prefix
    assert_equal "{BMX}", Client::BMX_PREFIX
  end

  # -- build_bmx_message ------------------------------------------------------
  #
  # Framing verified on a live stock BMX broker (a local IRIS container of a
  # built 9.0 image, rpms-rpc#282). The earlier form — a "^" between the proto
  # header and the message, and ";1" after the 5-digit length — made PRSP^BMXMBRK
  # read an empty protocol string and mangled the RPC name. The forms below
  # resolve the RPC on the stock parser.

  def test_build_bmx_message_no_params_proto_header_then_message_no_caret
    msg = Client.new.build_bmx_message("XUS SIGNON SETUP")
    # proto_header "015RPMS_RPC;0;0;0;" is followed IMMEDIATELY by the message
    # (no caret), then the 5-digit length, a single "0" flag byte, then the name.
    # text bytesize 16 + 6 = 22 → "00022" + "0" + name.
    assert msg.start_with?("015RPMS_RPC;0;0;0;00022" + "0" + "XUS SIGNON SETUP")
    refute_includes msg, ";1"
    refute_includes msg, "RPMS_RPC;0;0;0;^"
  end

  def test_build_bmx_message_frames_scalar_params_length_prefixed
    # PRSB param block: MMMMM (total) + per param LLL(value_len+1) + TYPE "0" + value.
    msg = Client.new.build_bmx_message("AGG LOOKUP PATIENTS", [ "DEMO", "N" ])
    # text = "AGG LOOKUP PATIENTS^" + block
    #   block = "00013" + ("005" "0" "DEMO") + ("002" "0" "N")   # 8+5 = 13 bytes
    assert_includes msg, "AGG LOOKUP PATIENTS^00013" + "0050DEMO" + "0020N"
  end

  def test_build_bmx_message_carries_a_caret_inside_a_scalar_value
    # PRSA splits only at the FIRST caret (name|block); PRSB then reads the value
    # by length, so a caret INSIDE a value crosses intact (the old scheme could
    # not — it is why XUS CVC was unsupported over BMX before #282).
    msg = Client.new.build_bmx_message("XUS CVC", [ "encA^encB^encC" ])
    # value is 14 bytes → LLL = 15 → "015"; inner = 3+1+14 = 18 → block "00018"
    assert_includes msg, "XUS CVC^00018" + "015" + "0" + "encA^encB^encC"
  end

  # -- byte-safety (multibyte / binary) --------------------------------------

  def test_build_bmx_message_is_binary_encoded
    msg = Client.new.build_bmx_message("XUS SIGNON SETUP")
    assert_equal Encoding::ASCII_8BIT, msg.encoding
  end

  def test_build_bmx_message_uses_bytesize_for_multibyte_input
    # value "héllo" = 6 bytes (é=2) → LLL = 6+1 = 7 → "007"
    msg = Client.new.build_bmx_message("ECHO", [ "héllo" ])
    assert msg.start_with?("015RPMS_RPC;0;0;0;".b)
    assert_includes msg, "ECHO^00010" + "0070héllo".b
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

  # -- hermetic round trip, built from bytes captured on a live stock broker --
  #
  # A local IRIS container of a built 9.0 image (rpms-rpc#282), 2026-10-02. The
  # replies below are the real framing: SNDERR writes len(security)+security +
  # len(app)+app, then the data, then EOT (BMXMON.m SNDERR/SND).

  class RecordingSocket
    attr_reader :writes

    def initialize(reads = [])
      @reads = reads.dup
      @writes = []
    end

    def write(str) = (@writes << str.b) && str.bytesize
    def recv(_n) = @reads.empty? ? "" : @reads.shift.b
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

  # Connect is TWO packets: the monitor TCPconnect that spawns the child session
  # (no reply), then the session-framed TCPconnect the child answers with
  # "accept"+EOT. A client that sends one packet and reads hangs.
  def test_connect_sends_monitor_then_session_tcpconnect_and_accepts
    client = Client.new
    client.instance_variable_set(:@timeout, 1)
    sock = RecordingSocket.new([ "\x00\x00accept\x04" ])
    client.define_singleton_method(:open_socket) { |*| @socket = sock }

    assert client.connect
    assert client.connected?
    writes = sock.writes
    assert_equal 2, writes.length, "connect must send monitor + session TCPconnect"
    assert_equal "{BMX}00010TCPconnect", writes[0]
    # session packet: {BMX} + TTTTT(=PLEN+5) + PPPPP + "TCPconnect"
    assert_equal "{BMX}0001500010TCPconnect", writes[1]
  end

  # The point of #282: an AG rejection comes back over BMX in the SECURITY
  # packet, where the gem surfaces it as an error — whereas the CIA broker never
  # returns BMXSEC, so the same rejection reads as success. These are the exact
  # bytes a non-exempt RPC drew pre-sign-on (CHKPRMIT^BMXMSEC via $$CHK^XQCS).
  def test_a_security_packet_rejection_surfaces_as_an_error
    msg = "The remote procedure AGG ADD NEW PATIENT is not registered to the option XUS SIGNON."
    reply = msg.bytesize.chr + msg + "\x00" + "\x04"
    client = connected_client([ reply ])

    error = assert_raises(RpmsRpc::Client::ConnectionError) do
      client.call_rpc("AGG ADD NEW PATIENT", "Mini Registration", "", "AGGPTLNM=DEMOPATIENT")
    end
    assert_match(/not registered to the option/i, error.message)
  end

  # A clean data reply (both packet lengths 0) passes through unchanged on the
  # raw path.
  def test_a_resolved_data_reply_passes_through
    client = connected_client([ "\x00\x00" + "1^DATA^ROW" + "\x04" ])
    assert_equal "1^DATA^ROW", client.call_rpc_raw("SOME READ")
  end

  # BMXMON's ETRAP writes "M ERROR=" with ONE space and it arrives as DATA
  # (both packet lengths 0), so check_for_rpc_error must catch the one-space
  # form or it reads as a successful reply (the <NOTOPEN> seen live on #282).
  def test_a_one_space_m_error_is_detected_on_call_rpc
    client = connected_client([ "\x00\x00" + "M ERROR=<NOTOPEN>CAPI+5^BMXMBRK2" + "\x04" ])
    error = assert_raises(RpmsRpc::Client::RpcError) { client.call_rpc("XWB IM HERE") }
    assert_match(/NOTOPEN/, error.message)
  end

  # WIRE-LEVEL regression for the sign-on path: the encoded frame must carry the
  # encrypted AV pair as exactly ONE length-framed BMX parameter, and that
  # parameter must decrypt back to the pair. PRSB reads the value by length, so
  # the ciphertext crosses intact regardless of its bytes.
  def test_the_encrypted_av_pair_crosses_the_bmx_wire_as_one_parameter
    client = connected_client([
      "\x00\x00OK\x04",                    # XUS SIGNON SETUP
      "\x00\x00301\r\n0\r\n0\r\nHi\x04"    # XUS AV CODE
    ])

    result = client.authenticate("AC123", "VC123!")
    assert result[:success]

    # Decode the one parameter back OUT of the frame (the cipher is
    # non-deterministic, so re-encrypting would not match): after "XUS AV CODE^"
    # comes the 5-digit block total, then one param: 3-digit (len+1), 1 type
    # byte, then the value.
    av_frame = client.instance_variable_get(:@socket).writes.last
    block = av_frame.b.split("XUS AV CODE^".b, 2).last
    inner = block.byteslice(5, block.byteslice(0, 5).to_i)
    vlen = inner.byteslice(0, 3).to_i - 1
    value = inner.byteslice(4, vlen)
    assert_equal vlen, value.bytesize,
      "the AV pair did not cross as one length-framed BMX parameter"
    assert_equal "AC123;VC123!", RpmsRpc::XwbCipher.decrypt(value),
      "the single wire parameter does not decrypt back to the AV pair"
  end

  # A caret-bearing scalar (XUS CVC's "^"-joined triple) now crosses as ONE
  # param — PRSB reads by length — so change_verify_code no longer raises a
  # transport limitation on BMX; it writes the frame.
  def test_change_verify_code_over_bmx_sends_the_frame
    require "rpms_rpc/api/authentication"
    client = connected_client([
      "\x00\x00OK\x04",          # XUS SIGNON SETUP (resolve)
      "\x00\x001\x04"            # XUS CVC -> success
    ])
    RpmsRpc.configure { |c| c.client = client }

    RpmsRpc::Authentication.change_verify_code(
      old_verify_code: "OLD1!", new_verify_code: "NEW2!", confirm_verify_code: "NEW2!"
    )
    refute_empty client.instance_variable_get(:@socket).writes
  ensure
    RpmsRpc.reset!
  end
end
