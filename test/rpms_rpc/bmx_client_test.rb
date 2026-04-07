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
end
