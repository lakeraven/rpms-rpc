# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/response_parser"

class RpmsRpc::ResponseParserTest < Minitest::Test
  Parser = RpmsRpc::ResponseParser

  # -- pick_string ------------------------------------------------------------

  def test_pick_string_finds_case_insensitive_match
    row = { "PatientDFN" => "123", "Name" => "DEMO,PATIENT" }
    assert_equal "123", Parser.pick_string(row, "dfn", "patientdfn")
  end

  def test_pick_string_returns_first_non_empty
    row = { "DFN" => "", "PatientDfn" => "456" }
    assert_equal "456", Parser.pick_string(row, "DFN", "PatientDfn")
  end

  def test_pick_string_returns_empty_for_nil_row
    assert_equal "", Parser.pick_string(nil, "DFN")
  end

  def test_pick_string_returns_empty_when_no_keys_match
    row = { "Other" => "value" }
    assert_equal "", Parser.pick_string(row, "DFN")
  end

  # -- pick_value -------------------------------------------------------------

  def test_pick_value_returns_raw_value
    row = { "Count" => 42 }
    assert_equal 42, Parser.pick_value(row, "count")
  end

  def test_pick_value_returns_nil_when_missing
    assert_nil Parser.pick_value({}, "missing")
  end

  # -- piece ------------------------------------------------------------------

  def test_piece_extracts_caret_delimited_field
    assert_equal "DEMO,PATIENT", Parser.piece("DEMO,PATIENT^123^M^19800101", 1)
    assert_equal "123", Parser.piece("DEMO,PATIENT^123^M^19800101", 2)
    assert_equal "M", Parser.piece("DEMO,PATIENT^123^M^19800101", 3)
  end

  def test_piece_returns_empty_for_out_of_range
    assert_equal "", Parser.piece("a^b", 5)
  end

  def test_piece_returns_empty_for_nil_or_empty
    assert_equal "", Parser.piece(nil, 1)
    assert_equal "", Parser.piece("", 1)
  end

  def test_piece_returns_empty_for_zero_or_negative
    assert_equal "", Parser.piece("a^b", 0)
    assert_equal "", Parser.piece("a^b", -1)
  end

  # -- pipe_piece -------------------------------------------------------------

  def test_pipe_piece_extracts_pipe_delimited_field
    assert_equal "begin", Parser.pipe_piece("begin|end|dfn", 1)
    assert_equal "dfn", Parser.pipe_piece("begin|end|dfn", 3)
  end

  # -- pipe_param -------------------------------------------------------------

  def test_pipe_param_joins_values_with_pipes
    assert_equal "3250101|3251231|123", Parser.pipe_param("3250101", "3251231", "123")
  end

  # -- parse_result -----------------------------------------------------------

  def test_parse_result_handles_nil
    result = Parser.parse_result(nil)
    assert result.success?
  end

  def test_parse_result_treats_nil_as_failure_when_empty_is_failure
    result = Parser.parse_result(nil, empty_is_success: false)
    refute result.success?
    assert_equal "No response from server", result.message
  end

  def test_parse_result_detects_error_in_caret_response
    result = Parser.parse_result("-1^Patient not found")
    refute result.success?
    assert_equal "Patient not found", result.message
  end

  def test_parse_result_detects_success_code
    result = Parser.parse_result("1^OK")
    assert result.success?
  end

  def test_parse_result_detects_error_column_in_row
    row = { "ERROR" => "Database locked" }
    result = Parser.parse_result(row)
    refute result.success?
    assert_equal "Database locked", result.message
  end

  def test_parse_result_uses_first_array_row
    rows = [ { "STATUS" => "OK", "ID" => "42" }, { "STATUS" => "OK", "ID" => "43" } ]
    result = Parser.parse_result(rows)
    assert result.success?
  end

  # -- rows_from_delimited ----------------------------------------------------

  def test_rows_from_delimited_parses_header_and_rows
    lines = [ "ID^NAME^DOB", "1^DEMO,PATIENT^19800101", "2^TEST,USER^19900515" ]
    rows = Parser.rows_from_delimited(lines)
    assert_equal 2, rows.length
    assert_equal "1", rows[0]["ID"]
    assert_equal "DEMO,PATIENT", rows[0]["NAME"]
    assert_equal "TEST,USER", rows[1]["NAME"]
  end

  def test_rows_from_delimited_returns_empty_for_nil
    assert_equal [], Parser.rows_from_delimited(nil)
  end

  def test_rows_from_delimited_returns_empty_when_only_header
    assert_equal [], Parser.rows_from_delimited([ "ID^NAME" ])
  end

  # -- RpcResult --------------------------------------------------------------

  def test_rpc_result_predicates
    success = Parser::RpcResult.new(success: true, message: "ok")
    assert success.success?
    refute success.failure?

    failure = Parser::RpcResult.new(success: false, message: "boom")
    refute failure.success?
    assert failure.failure?
  end
end
