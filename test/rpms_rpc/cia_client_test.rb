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

  # -- byte-safety (multibyte / binary) --------------------------------------

  def test_spack_uses_bytesize_for_multibyte
    # "é" is 2 bytes in UTF-8 → length prefix must be 2, not 1
    result = Client.new.spack("é")
    assert_equal Encoding::ASCII_8BIT, result.encoding
    assert_equal 2, result.bytes[0]
    assert_equal 3, result.bytesize # 1 byte length + 2 byte value
  end

  def test_spack_raises_when_value_exceeds_255_bytes
    long = "x" * 256
    assert_raises(Client::SpackTooLongError) { Client.new.spack(long) }
  end

  def test_spack_accepts_exactly_255_bytes
    on_the_line = "x" * 255
    result = Client.new.spack(on_the_line)
    assert_equal 255, result.bytes[0]
    assert_equal 256, result.bytesize
  end

  def test_lpack_uses_bytesize_for_multibyte
    # "héllo" = 6 bytes in UTF-8 (h=1, é=2, l=1, l=1, o=1)
    result = Client.new.lpack("héllo")
    assert_equal Encoding::ASCII_8BIT, result.encoding
    assert result.start_with?("006")
    assert_equal 9, result.bytesize # "006" + 6 bytes
  end

  def test_lpack_uses_five_digit_width_at_byte_threshold
    # 500 multibyte chars × 2 bytes = 1000 bytes → triggers 5-digit width
    long = "é" * 500
    result = Client.new.lpack(long)
    assert result.start_with?("01000")
    assert_equal 1005, result.bytesize
  end

  def test_build_rpc_message_is_binary_encoded
    msg = Client.new.build_rpc_message("XUS SIGNON SETUP")
    assert_equal Encoding::ASCII_8BIT, msg.encoding
  end

  def test_build_rpc_message_with_multibyte_param_uses_bytesize
    client = Client.new
    msg = client.build_rpc_message("ECHO", [ client.literal_param("héllo") ])
    assert_equal Encoding::ASCII_8BIT, msg.encoding
    # 6-byte body, 3-digit length width → "0006héllo" (in bytes)
    assert_includes msg, "0006héllo".b
  end

  def test_build_connect_message_is_binary_encoded
    msg = Client.new.build_connect_message("10.0.0.1", "myapp")
    assert_equal Encoding::ASCII_8BIT, msg.encoding
  end

  # -- subclass contract ------------------------------------------------------

  def test_call_rpc_raises_when_not_connected
    assert_raises(RpmsRpc::Client::ConnectionError) { Client.new.call_rpc("XUS SIGNON SETUP") }
  end

  def test_call_rpc_raw_raises_when_not_connected
    assert_raises(RpmsRpc::Client::ConnectionError) { Client.new.call_rpc_raw("XUS SIGNON SETUP") }
  end

  # -- list-param encoding (for multi-line RPC payloads like BEHOVM SAVE) ----

  def test_encode_param_wraps_scalar_as_literal
    encoded = Client.new.encode_param("hello")
    assert_equal({ type: :literal, value: "hello" }, encoded)
  end

  def test_encode_param_passes_through_prebuilt_literal
    pre = { type: :literal, value: "x" }
    assert_equal pre, Client.new.encode_param(pre)
  end

  def test_encode_param_passes_through_prebuilt_list
    pre = { type: :list, entries: [ [ "1", "a" ] ] }
    assert_equal pre, Client.new.encode_param(pre)
  end

  def test_encode_param_wraps_array_as_list_with_one_based_string_keys
    encoded = Client.new.encode_param([ "HDR^^^v1", "VST^DT^now", "VIT+^TMP^0^^97" ])
    assert_equal :list, encoded[:type]
    keys = encoded[:entries].map(&:first)
    vals = encoded[:entries].map(&:last)
    assert_equal [ "1", "2", "3" ], keys
    assert_equal [ "HDR^^^v1", "VST^DT^now", "VIT+^TMP^0^^97" ], vals
  end

  def test_encode_param_wraps_hash_as_list_with_string_keys
    encoded = Client.new.encode_param(a: 1, b: 2)
    assert_equal :list, encoded[:type]
    assert_equal [ [ "a", "1" ], [ "b", "2" ] ], encoded[:entries]
  end

  # A business hash that incidentally has a :type key must still be encoded
  # as a list param, not silently passed through. Only :type == :literal or
  # :type == :list are protocol kinds.
  def test_encode_param_wraps_business_hash_with_type_key_as_list
    encoded = Client.new.encode_param(name: "foo", type: "user")
    assert_equal :list, encoded[:type]
    keys = encoded[:entries].map(&:first)
    assert_includes keys, "name"
    assert_includes keys, "type"
  end

  def test_encode_param_rejects_pass_through_for_unknown_type_value
    encoded = Client.new.encode_param({ type: :something_random, value: "x" })
    # Unknown :type should NOT be passed through; encode as a list.
    assert_equal :list, encoded[:type]
  end

  def test_build_rpc_message_emits_list_param_bytes_for_array_payload
    client = Client.new
    msg = client.build_rpc_message("BEHOVM SAVE", [
      client.encode_param("8791"),
      client.encode_param([ "HDR^^^v1", "VST^DT^now" ])
    ])
    # XWB param spec uses "0" for literal, "2" for list. The list entries
    # should appear verbatim in the packet body — NOT as a Ruby array
    # literal (e.g. "[\"HDR^^^v1\", \"VST^DT^now\"]").
    assert_includes msg, "BEHOVM SAVE"
    assert_includes msg, "HDR^^^v1"
    assert_includes msg, "VST^DT^now"
    refute_includes msg, "[\"HDR", "Array params must be encoded as XWB list, not Ruby array literal"
  end
end
