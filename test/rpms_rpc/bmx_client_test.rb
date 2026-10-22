# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require "rpms_rpc/bmx_client"
require "rpms_rpc/data_mapper"

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
  # packet, where the gem surfaces it as an error (since #363 the typed
  # RpcRefusedError: served, but not to this user) — whereas the CIA broker never
  # returns BMXSEC, so the same rejection reads as success. These are the exact
  # bytes a non-exempt RPC drew pre-sign-on (CHKPRMIT^BMXMSEC via $$CHK^XQCS).
  def test_a_security_packet_rejection_surfaces_as_an_error
    msg = "The remote procedure AGG ADD NEW PATIENT is not registered to the option XUS SIGNON."
    reply = msg.bytesize.chr + msg + "\x00" + "\x04"
    client = connected_client([ reply ])

    error = assert_raises(RpmsRpc::Client::RpcRefusedError) do
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
      "\x00\x00301\r\n0\r\n0\r\nHi\x04",   # XUS AV CODE
      "\x00\x000\x04",                   # XUS DIVISION GET (#450): one division, set server-side
      "\x00\x004\r\nX\r\nX\r\n7819^DEMO IHS CLINIC^8904\x04" # XUS GET USER INFO
    ])

    result = client.authenticate("AC123", "VC123!")
    assert result[:success]

    # Decode the one parameter back OUT of the frame (the cipher is
    # non-deterministic, so re-encrypting would not match): after "XUS AV CODE^"
    # comes the 5-digit block total, then one param: 3-digit (len+1), 1 type
    # byte, then the value.
    av_frame = client.instance_variable_get(:@socket).writes.find { |w| w.b.include?("XUS AV CODE^".b) }
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
  # -- replies captured from a live stock BMX session (rpms-rpc#200) ----------
  #
  # test/fixtures/bmx/replies.yml holds each frame VERBATIM, every byte the
  # broker wrote for one call (see its header for the image and date). No frame
  # below is hand-written.

  REPLIES = YAML.safe_load_file(File.expand_path("../fixtures/bmx/replies.yml", __dir__))

  def frame(name) = REPLIES.fetch(name).fetch("frame").b

  # A recordset is ONE line on the BMX wire: $C(30) ends each node, $C(31)
  # starts the last. call_rpc splits at $C(30) and drops the end marker, as
  # CiaClient#call_rpc does, so the DataMapper sees the header row and records.
  def test_a_recordset_reply_splits_into_its_header_and_rows
    client = connected_client([ frame("rows") ])
    assert_equal [ "T00016NAME", "ADAM,ADAM", "BSTS,PROXY USER" ], client.call_rpc("BMX SQL", "q")
  end

  def test_a_multi_column_recordset_keeps_each_row_caret_delimited
    client = connected_client([ frame("rows_two_columns") ])
    assert_equal [ "T00015NAME^T00005SEX", "USER,TEST^MALE", "MOUSE,MICKEY M^MALE" ],
                 client.call_rpc("BMX SQL", "q")
  end

  # A query that matches nothing answers its typed header and the end marker:
  # an empty result set, not an error, and no data row.
  def test_a_header_only_reply_is_an_empty_result_not_an_error
    rows = connected_client([ frame("header_only") ]).call_rpc("BMX SQL", "q")
    assert_equal [ "T00050NAME" ], rows
    assert_empty rows.reject { |r| RpmsRpc::DataMapper.recordset_header_row?(r) }
  end

  # ERRTRAP^BMXSQL answers an M error as a one-column recordset, M_ERROR, whose
  # row is $$EC^%ZOSV (here %YDB-E-LVUNDEF). It is an RpcMError, never a row.
  def test_an_m_error_recordset_raises_instead_of_returning_rows
    client = connected_client([ frame("m_error_recordset") ])
    error = assert_raises(RpmsRpc::Client::RpcMError) { client.call_rpc("BMX SQL", "q") }
    assert_includes error.message, "%YDB-E-LVUNDEF"
    assert_includes error.message, "FIELDS+14~BMXSQL6"
  end

  # ERRTACK^BMXSQL writes the query error AFTER the $C(31) end marker.
  def test_text_after_the_recordset_end_marker_raises_as_a_query_error
    client = connected_client([ frame("query_error") ])
    error = assert_raises(RpmsRpc::Client::RpcError) { client.call_rpc("BMX SQL", "q") }
    refute_kind_of RpmsRpc::Client::RpcMError, error
    assert_includes error.message, "FIELD NOT FOUND"
  end

  # BMXMON's ETRAP: "M ERROR=" (one space) as DATA, both packet lengths 0.
  def test_an_etrap_m_error_with_a_ydb_code_raises
    client = connected_client([ frame("m_error_etrap") ])
    error = assert_raises(RpmsRpc::Client::RpcMError) { client.call_rpc("BMX SQL", "a", "b", "c", "d", "e") }
    assert_includes error.message, "%YDB-E-ACTLSTTOOLONG"
  end

  # The read order: len(security) + security, len(application) + application,
  # data, EOT. An unknown RPC is refused in the security packet.
  def test_an_unknown_rpc_is_refused_in_the_security_packet
    client = connected_client([ frame("unknown_rpc") ])
    assert_raises(RpmsRpc::Client::RpcNotAvailableError) { client.call_rpc("ZZZ NO SUCH RPC") }
  end

  # The security text quotes the RPC name, so it can carry an EOT byte. Read by
  # its length byte, the whole frame is consumed and the NEXT call reads its own
  # reply. Both frames arrive in one segment, and again a byte at a time.
  def test_an_eot_inside_the_security_text_does_not_desynchronize_the_socket
    [ [ frame("unknown_rpc_eot_in_name") + frame("header_only") ],
      (frame("unknown_rpc_eot_in_name") + frame("header_only")).chars ].each do |reads|
      client = connected_client(reads)
      error = assert_raises(RpmsRpc::Client::RpcNotAvailableError) { client.call_rpc("ZZ\x04ZZ") }
      assert_includes error.message, "doesn't exist on the server"
      assert_equal [ "T00050NAME" ], client.call_rpc("BMX SQL", "q"),
                   "the next call read the tail of the previous reply"
    end
  end
end

# -- #450: sign-on binds the division as the stock XWB/BMX client does ------
class BmxClientDivisionTest < Minitest::Test
  Client = RpmsRpc::BmxClient

  SETUP = "\x00\x00OK\x04"
  AV_OK = "\x00\x00301\r\n0\r\n0\r\nHi\x04"
  # DIVGET^XUSRB2 for a one-division user: it set DUZ(2) itself and answers 0, no rows
  ONE_DIVISION = "\x00\x000\x04"
  USER_INFO = "\x00\x004\r\nMANAGER,SYSTEM\r\nMANAGER,SYSTEM\r\n7819^DEMO IHS CLINIC^8904\r\n\r\n\r\n\r\n300\x04"
  TWO_DIVISIONS = "\x00\x002\r\n7819^DEMO IHS CLINIC^8904^0\r\n7870^TUCSON MEDICAL CENTER^8905^1\x04"
  TWO_NO_DEFAULT = "\x00\x002\r\n7819^DEMO IHS CLINIC^8904^0\r\n7870^TUCSON MEDICAL CENTER^8905^0\x04"
  SET_OK = "\x00\x001\x04"
  SET_NO = "\x00\x000\x04"

  def connected_client(reads)
    c = Client.new
    c.instance_variable_set(:@socket, RpmsRpc::BmxClientTest::RecordingSocket.new(reads))
    c.instance_variable_set(:@connected, true)
    c.instance_variable_set(:@timeout, 5)
    c
  end

  def writes(c) = c.instance_variable_get(:@socket).writes

  # One division: DIVGET set DUZ(2) itself and answered 0, so no DIVSET is
  # sent and the bound division is read back from XUS GET USER INFO.
  def test_one_division_binds_without_a_set
    c = connected_client([ SETUP, AV_OK, ONE_DIVISION, USER_INFO ])
    result = c.authenticate("AC123", "VC123!")
    assert_equal 7819, result[:division]
    assert_equal({ ien: 7819, name: "DEMO IHS CLINIC", station: "8904", default: true }, c.division)
    assert_equal [ c.division ], c.divisions
    refute(writes(c).any? { |w| w.include?("XUS DIVISION SET") })
    assert(writes(c).any? { |w| w.include?("XUS GET USER INFO") })
  end

  # One division and a named one: DIVSET decides (the server checks membership).
  def test_one_division_named_goes_through_divset
    c = connected_client([ SETUP, AV_OK, ONE_DIVISION, SET_OK, USER_INFO ])
    result = c.authenticate("AC123", "VC123!", division: 7819)
    assert_equal 7819, result[:division]
    assert(writes(c).any? { |w| w.include?("XUS DIVISION SET") && w.include?("`7819") })
  end

  def test_one_division_named_wrongly_is_refused_by_the_server
    c = connected_client([ SETUP, AV_OK, ONE_DIVISION, SET_NO ])
    error = assert_raises(RpmsRpc::Client::AuthenticationError) { c.authenticate("AC123", "VC123!", division: 9999) }
    assert_match(/XUS DIVISION SET 9999 answered/, error.message)
    refute c.authenticated?
  end

  # Several divisions, none named: the one flagged default is set, as the
  # stock client's picker would preselect it.
  def test_several_divisions_bind_the_default_with_a_set
    c = connected_client([ SETUP, AV_OK, TWO_DIVISIONS, SET_OK ])
    result = c.authenticate("AC123", "VC123!")
    assert_equal 7870, result[:division]
    assert(writes(c).any? { |w| w.include?("XUS DIVISION SET") && w.include?("`7870") })
  end

  # Several divisions and no default: the client does not guess.
  def test_several_divisions_with_no_default_fail_closed
    c = connected_client([ SETUP, AV_OK, TWO_NO_DEFAULT ])
    error = assert_raises(RpmsRpc::Client::AuthenticationError) { c.authenticate("AC123", "VC123!") }
    assert_match(/none is the default/, error.message)
    refute c.authenticated?
    assert_nil c.duz
  end

  # A named division is one of the user's and DIVSET answers 1.
  def test_naming_one_of_the_users_divisions_sets_it
    c = connected_client([ SETUP, AV_OK, TWO_DIVISIONS, SET_OK ])
    result = c.authenticate("AC123", "VC123!", division: 7819)
    assert_equal 7819, result[:division]
    assert(writes(c).any? { |w| w.include?("XUS DIVISION SET") && w.include?("`7819") })
  end

  # A division the user lacks is refused before any DIVSET, signed off.
  def test_naming_a_division_the_user_lacks_fails_closed
    c = connected_client([ SETUP, AV_OK, TWO_DIVISIONS ])
    error = assert_raises(RpmsRpc::Client::AuthenticationError) { c.authenticate("AC123", "VC123!", division: 9999) }
    assert_match(/not one of DUZ 301's divisions/, error.message)
    refute(writes(c).any? { |w| w.include?("XUS DIVISION SET") })
    refute c.authenticated?
    assert_nil c.division
  end

  # DIVSET^XUSRB2 answers 0 when it did not set DUZ(2): the client believes
  # the server, not its own list.
  def test_a_set_the_server_refuses_fails_closed
    c = connected_client([ SETUP, AV_OK, TWO_DIVISIONS, SET_NO ])
    error = assert_raises(RpmsRpc::Client::AuthenticationError) { c.authenticate("AC123", "VC123!", division: 7819) }
    assert_match(/XUS DIVISION SET 7819 answered/, error.message)
    refute c.authenticated?
  end
end
