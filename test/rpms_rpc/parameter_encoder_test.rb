# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/parameter_encoder"

class RpmsRpc::ParameterEncoderTest < Minitest::Test
  Encoder = RpmsRpc::ParameterEncoder
  EOT = Encoder::EOT

  def test_encode_string_uses_vista_format
    result = Encoder.encode("hello")
    assert_equal "100500fhello#{EOT}", result
  end

  def test_encode_pads_length_to_three_digits
    result = Encoder.encode("a")
    assert_equal "100100fa#{EOT}", result
  end

  def test_encode_uses_byte_size_not_character_count
    # 2-byte UTF-8 character
    result = Encoder.encode("é")
    assert_equal "100200fé#{EOT}", result
  end

  def test_encode_nil_as_empty_string
    result = Encoder.encode(nil)
    assert_equal "100000f#{EOT}", result
  end

  def test_encode_booleans
    assert_equal "100400ftrue#{EOT}", Encoder.encode(true)
    assert_equal "100500ffalse#{EOT}", Encoder.encode(false)
  end

  def test_encode_array_joins_with_newlines
    result = Encoder.encode([ "a", "b", "c" ])
    assert_equal "100500fa\nb\nc#{EOT}", result
  end

  def test_encode_raises_when_too_long
    long_string = "x" * 1000
    assert_raises(Encoder::ParameterTooLongError) { Encoder.encode(long_string) }
  end

  def test_encode_list_joins_multiple_params
    result = Encoder.encode_list([ "a", "b" ])
    assert_equal "100100fa#{EOT}100100fb#{EOT}", result
  end

  def test_encode_list_returns_empty_for_nil
    assert_equal "", Encoder.encode_list(nil)
  end

  def test_encode_hash_serializes_as_key_value_lines
    result = Encoder.encode_hash(name: "John", age: "30")
    assert_includes result, "name=John"
    assert_includes result, "age=30"
  end

  def test_decode_extracts_value_from_encoded_string
    encoded = "100500fhello#{EOT}"
    assert_equal "hello", Encoder.decode(encoded)
  end

  def test_decode_returns_empty_for_nil
    assert_equal "", Encoder.decode(nil)
  end

  def test_decode_passes_through_unrecognized_format
    assert_equal "raw value", Encoder.decode("raw value")
  end
end
