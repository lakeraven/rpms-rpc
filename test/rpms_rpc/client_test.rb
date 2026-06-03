# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/client"

class RpmsRpc::ClientTest < Minitest::Test
  Client = RpmsRpc::Client

  def setup
    @prev_host = ENV["VISTA_RPC_HOST"]
    @prev_port = ENV["VISTA_RPC_PORT"]
    @prev_timeout = ENV["VISTA_RPC_TIMEOUT"]
    ENV.delete("VISTA_RPC_HOST")
    ENV.delete("VISTA_RPC_PORT")
    ENV.delete("VISTA_RPC_TIMEOUT")
  end

  def teardown
    ENV["VISTA_RPC_HOST"] = @prev_host
    ENV["VISTA_RPC_PORT"] = @prev_port
    ENV["VISTA_RPC_TIMEOUT"] = @prev_timeout
  end

  # -- defaults ---------------------------------------------------------------

  def test_defaults_to_localhost_and_default_port
    client = Client.new
    assert_equal "localhost", client.host
    assert_equal 9100, client.port
    assert_equal 30, client.timeout
  end

  def test_reads_host_port_timeout_from_env
    ENV["VISTA_RPC_HOST"] = "vista.example.com"
    ENV["VISTA_RPC_PORT"] = "9200"
    ENV["VISTA_RPC_TIMEOUT"] = "60"
    client = Client.new
    assert_equal "vista.example.com", client.host
    assert_equal 9200, client.port
    assert_equal 60, client.timeout
  end

  def test_explicit_kwargs_override_env
    ENV["VISTA_RPC_HOST"] = "env.example.com"
    client = Client.new(host: "explicit.example.com", port: 5555, timeout: 10)
    assert_equal "explicit.example.com", client.host
    assert_equal 5555, client.port
    assert_equal 10, client.timeout
  end

  # -- error class hierarchy --------------------------------------------------

  def test_error_classes_defined
    assert Client::ConnectionError < StandardError
    assert Client::AuthenticationError < StandardError
    assert Client::RpcError < StandardError
    assert Client::TimeoutError < Client::ConnectionError
  end

  def test_eot_constant
    assert_equal "\x04", Client::EOT
  end

  def test_cipher_table_has_twenty_rows
    assert_equal 20, Client::CIPHER_TABLE.length
    Client::CIPHER_TABLE.each { |row| assert_equal 94, row.length }
  end

  # -- connection state -------------------------------------------------------

  def test_not_connected_by_default
    client = Client.new
    refute client.connected?
    refute client.authenticated?
    assert_nil client.duz
  end

  def test_set_authenticated_records_duz
    client = Client.new
    client.set_authenticated("123")
    assert client.authenticated?
    assert_equal "123", client.duz
  end

  def test_connected_predicate_requires_handshake_flag_not_just_socket
    # A live socket alone is not enough — the handshake must have completed.
    # This guards against the prior bug where error/timeout paths cleared
    # @connected but connected? still returned true because the socket
    # object existed.
    client = Client.new
    sock = StringIO.new
    client.instance_variable_set(:@socket, sock)
    refute client.connected?, "socket present but @connected=false → must report disconnected"

    client.instance_variable_set(:@connected, true)
    assert client.connected?

    sock.close
    refute client.connected?, "closed socket → must report disconnected"
  end

  # -- xwb_encrypt ------------------------------------------------------------

  def test_xwb_encrypt_returns_string_with_index_chars
    client = Client.new
    encrypted = client.xwb_encrypt("HELLO")
    # First and last bytes are row index + 32 (printable ASCII space..)
    refute_equal "HELLO", encrypted
    assert encrypted.length >= 7 # 1 + 5 + 1
    first_idx = encrypted[0].ord - 32
    last_idx = encrypted[-1].ord - 32
    assert (0..19).include?(first_idx)
    assert (1..19).include?(last_idx)
    refute_equal first_idx, last_idx
  end

  def test_xwb_encrypt_passes_through_chars_not_in_row
    client = Client.new
    # Pick a character unlikely in row_a — but algorithm passes through
    # any char not found. Just verify it returns a string of expected length.
    encrypted = client.xwb_encrypt("a")
    assert_equal 3, encrypted.length
  end

  # -- parse_rpc_response -----------------------------------------------------

  def test_parse_rpc_response_returns_empty_for_nil
    assert_equal [], Client.new.parse_rpc_response(nil)
  end

  def test_parse_rpc_response_returns_empty_for_blank_string
    assert_equal [], Client.new.parse_rpc_response("   ")
  end

  def test_parse_rpc_response_passes_through_non_xml
    assert_equal "raw value", Client.new.parse_rpc_response("raw value")
  end

  def test_parse_rpc_response_parses_xml_via_parser
    xml = <<~XML
      <vistalink type="Gov.VA.Med.RPC.Response">
        <results type="string"><![CDATA[hello]]></results>
      </vistalink>
    XML
    assert_equal "hello", Client.new.parse_rpc_response(xml)
  end

  # -- subclass contract ------------------------------------------------------

  def test_call_rpc_must_be_implemented_by_subclass
    client = Client.new
    assert_raises(NotImplementedError) { client.call_rpc("XUS SIGNON SETUP") }
  end

  def test_connect_must_be_implemented_by_subclass
    client = Client.new
    assert_raises(NotImplementedError) { client.connect("localhost", 9100) }
  end

  # -- guards -----------------------------------------------------------------

  def test_signon_setup_raises_when_not_connected
    assert_raises(Client::ConnectionError) { Client.new.signon_setup }
  end

  def test_create_context_raises_when_not_connected
    assert_raises(Client::ConnectionError) { Client.new.create_context }
  end

  # -- check_for_rpc_error: VistA-M error frame detection --------------------

  # Real wire shape observed against FOIA-RPMS when a BHS-namespace RPC
  # targets a routine that isn't installed on the server. The Broker prefixes
  # the error payload with \x18 (CAN, "wire-level error signal"), then the
  # literal "M  ERROR=" frame, then the runtime context.
  def test_check_for_rpc_error_raises_on_can_prefixed_m_error_frame
    payload = "\x18M  ERROR=<NOLINE>PTINFO+22^BEHOPTCX^"
    err = assert_raises(Client::RpcError) do
      Client.new.send(:check_for_rpc_error, payload)
    end
    assert_includes err.message, "NOLINE"
    assert_includes err.message, "BEHOPTCX"
  end

  # Some Brokers emit the error without the CAN sentinel. Keep the existing
  # bare-"M  ERROR=" case working as a regression guard.
  def test_check_for_rpc_error_raises_on_bare_m_error_frame
    payload = "M  ERROR=<UNDEFINED>FOO+5^BAR^"
    err = assert_raises(Client::RpcError) do
      Client.new.send(:check_for_rpc_error, payload)
    end
    assert_includes err.message, "UNDEFINED"
  end

  # Patient name happens to contain "M" — must not be misread as M error.
  def test_check_for_rpc_error_does_not_raise_on_data_containing_letter_m
    payload = "1^MOUSE,MICKEY M^M^2840214^"
    assert_nil Client.new.send(:check_for_rpc_error, payload)
  end

  def test_check_for_rpc_error_no_raise_on_empty_or_nil
    assert_nil Client.new.send(:check_for_rpc_error, "")
    assert_nil Client.new.send(:check_for_rpc_error, nil)
  end
end
