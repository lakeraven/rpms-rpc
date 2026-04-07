# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/cia_client"

class RpmsRpc::CiaClientTest < Minitest::Test
  Client = RpmsRpc::CiaClient
  EOT = RpmsRpc::Client::EOT

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

  def test_default_port_is_9100
    assert_equal 9100, Client.new.port
  end

  def test_xwb_prefix
    assert_equal "[XWB]1130", Client::XWB_PREFIX
  end

  # -- spack / lpack ----------------------------------------------------------

  def test_spack_prefixes_length_byte
    assert_equal "\x05hello", Client.new.spack("hello")
  end

  def test_lpack_uses_three_digit_length_for_short
    assert_equal "005hello", Client.new.lpack("hello")
  end

  def test_lpack_uses_five_digit_length_for_long
    long = "x" * 1000
    result = Client.new.lpack(long)
    assert_equal "01000#{long}", result
  end

  # -- build_connect_message --------------------------------------------------

  def test_build_connect_message_starts_with_xwb_prefix_and_command_token
    msg = Client.new.build_connect_message("10.0.0.1", "myapp")
    assert msg.start_with?("[XWB]11304") # prefix + token "4"
    assert msg.end_with?(EOT)
    assert_includes msg, "TCPConnect"
    assert_includes msg, "10.0.0.1"
    assert_includes msg, "myapp"
  end

  # -- build_rpc_message ------------------------------------------------------

  def test_build_rpc_message_with_no_params
    client = Client.new
    msg = client.build_rpc_message("XUS SIGNON SETUP")
    assert msg.start_with?("[XWB]11302\x011") # prefix + token "2\x011"
    assert msg.end_with?("54f#{EOT}") # param_spec "5" + "4f" + EOT
  end

  def test_build_rpc_message_with_literal_params
    client = Client.new
    params = [ client.literal_param("hello"), client.literal_param("world") ]
    msg = client.build_rpc_message("ECHO", params)
    # spack("ECHO") = chr(4) + "ECHO" = "\x04ECHO" — note byte clash with EOT
    assert_includes msg, "\x04ECHO"
    assert_includes msg, "0005hellof"
    assert_includes msg, "0005worldf"
    assert msg.end_with?(EOT)
  end

  def test_literal_and_list_param_helpers
    client = Client.new
    assert_equal({ type: :literal, value: "x" }, client.literal_param("x"))
    assert_equal({ type: :list, entries: { a: 1 } }, client.list_param(a: 1))
  end

  # -- subclass contract ------------------------------------------------------

  def test_call_rpc_raises_when_not_connected
    assert_raises(RpmsRpc::Client::ConnectionError) { Client.new.call_rpc("XUS SIGNON SETUP") }
  end

  def test_call_rpc_raw_raises_when_not_connected
    assert_raises(RpmsRpc::Client::ConnectionError) { Client.new.call_rpc_raw("XUS SIGNON SETUP") }
  end
end
