# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/data_mapper"

class RpmsRpc::DataMapperExtensionsTest < Minitest::Test
  # -- Line-based responses (one field per line, not per caret) ---------------

  def test_line_field_maps_by_line_number
    mapping = RpmsRpc::DataMapper.define(:line_test) do |m|
      m.rpc "XUS AV CODE"
      m.line_field 0, :duz, :integer
      m.line_field 5, :tries, :integer
    end

    lines = [ "101", "0", "0", "Welcome", "", "3" ]
    result = mapping.parse_lines(lines)

    assert_equal 101, result[:duz]
    assert_equal 3, result[:tries]
  end

  def test_line_field_returns_nil_for_missing_lines
    mapping = RpmsRpc::DataMapper.define(:line_short_test) do |m|
      m.rpc "TEST"
      m.line_field 0, :value
      m.line_field 5, :missing
    end

    result = mapping.parse_lines([ "hello" ])
    assert_equal "hello", result[:value]
    assert_nil result[:missing]
  end

  def test_line_field_with_extras
    mapping = RpmsRpc::DataMapper.define(:line_extras_test) do |m|
      m.rpc "TEST"
      m.line_field 0, :name
    end

    result = mapping.parse_lines([ "DOE,JOHN" ], extras: { source: "rpc" })
    assert_equal "DOE,JOHN", result[:name]
    assert_equal "rpc", result[:source]
  end

  def test_parse_lines_returns_nil_for_empty
    mapping = RpmsRpc::DataMapper.define(:line_empty_test) do |m|
      m.rpc "TEST"
      m.line_field 0, :value
    end

    assert_nil mapping.parse_lines(nil)
    assert_nil mapping.parse_lines([])
  end

  # -- Scalar responses (single value, no caret) -----------------------------

  def test_parse_scalar_returns_typed_value
    mapping = RpmsRpc::DataMapper.define(:scalar_bool_test) do |m|
      m.rpc "ORWPT SELCHK"
      m.scalar :sensitive, :boolean
    end

    assert_equal true, mapping.parse_scalar("1")
    assert_equal false, mapping.parse_scalar("0")
  end

  def test_parse_scalar_fileman_date
    mapping = RpmsRpc::DataMapper.define(:scalar_date_test) do |m|
      m.rpc "ORWPT DIEDON"
      m.scalar :deceased_date, :fileman_date
    end

    assert_equal Date.new(2025, 3, 15), mapping.parse_scalar("3250315")
  end

  def test_parse_scalar_string
    mapping = RpmsRpc::DataMapper.define(:scalar_str_test) do |m|
      m.rpc "TEST"
      m.scalar :status, :string
    end

    assert_equal "OK", mapping.parse_scalar("OK")
  end

  def test_parse_scalar_handles_array_response
    mapping = RpmsRpc::DataMapper.define(:scalar_array_test) do |m|
      m.rpc "TEST"
      m.scalar :active, :boolean
    end

    assert_equal true, mapping.parse_scalar([ "1", "extra" ])
  end

  def test_parse_scalar_returns_nil_for_empty
    mapping = RpmsRpc::DataMapper.define(:scalar_nil_test) do |m|
      m.rpc "TEST"
      m.scalar :value, :string
    end

    assert_nil mapping.parse_scalar("")
    assert_nil mapping.parse_scalar(nil)
    assert_nil mapping.parse_scalar([])
  end

  # -- Text blob responses (array of lines joined) ---------------------------

  def test_parse_text_joins_lines
    mapping = RpmsRpc::DataMapper.define(:text_test) do |m|
      m.rpc "ORWRP REPORT TEXT"
      m.text_blob :report_text
    end

    lines = [ "Patient: DOE,JOHN", "Date: 2025-03-15", "", "Report content here." ]
    result = mapping.parse_text(lines)

    assert_equal "Patient: DOE,JOHN\nDate: 2025-03-15\n\nReport content here.", result
  end

  def test_parse_text_returns_nil_for_empty
    mapping = RpmsRpc::DataMapper.define(:text_empty_test) do |m|
      m.rpc "TEST"
      m.text_blob :content
    end

    assert_nil mapping.parse_text(nil)
    assert_nil mapping.parse_text([])
  end

  def test_parse_text_handles_string_response
    mapping = RpmsRpc::DataMapper.define(:text_string_test) do |m|
      m.rpc "TEST"
      m.text_blob :content
    end

    assert_equal "single line", mapping.parse_text("single line")
  end
end
