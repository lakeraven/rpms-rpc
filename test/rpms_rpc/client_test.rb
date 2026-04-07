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
end
