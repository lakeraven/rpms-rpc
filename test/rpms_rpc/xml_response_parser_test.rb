# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/xml_response_parser"

class RpmsRpc::XmlResponseParserTest < Minitest::Test
  Parser = RpmsRpc::XmlResponseParser

  def test_parse_string_response
    xml = <<~XML
      <vistalink type="Gov.VA.Med.RPC.Response">
        <results type="string"><![CDATA[hello world]]></results>
      </vistalink>
    XML
    assert_equal "hello world", Parser.parse(xml)
  end

  def test_parse_array_response
    xml = <<~XML
      <vistalink type="Gov.VA.Med.RPC.Response">
        <results type="array"><![CDATA[
line1
line2
line3]]></results>
      </vistalink>
    XML
    result = Parser.parse(xml)
    assert_equal [ "line1", "line2", "line3" ], result
  end

  def test_parse_array_strips_leading_empty_line
    xml = <<~XML
      <vistalink type="Gov.VA.Med.RPC.Response">
        <results type="array"><![CDATA[
data]]></results>
      </vistalink>
    XML
    assert_equal [ "data" ], Parser.parse(xml)
  end

  def test_parse_error_response_raises
    xml = <<~XML
      <vistalink type="VA.RPC.Error">
        <errors>
          <error code="1234" uri="urn:test">
            <msg>Permission denied</msg>
          </error>
        </errors>
      </vistalink>
    XML

    err = assert_raises(Parser::RpcError) { Parser.parse(xml) }
    assert_equal "Permission denied", err.message
    assert_equal 1234, err.code
  end

  def test_parse_nil_raises_parse_error
    assert_raises(Parser::ParseError) { Parser.parse(nil) }
  end

  def test_parse_empty_raises_parse_error
    assert_raises(Parser::ParseError) { Parser.parse("") }
  end

  def test_parse_malformed_raises_parse_error
    assert_raises(Parser::ParseError) { Parser.parse("<not closed") }
  end

  def test_parse_returns_nil_for_unrecognized_root
    xml = "<other>content</other>"
    # Not a vistalink — falls through to normal response, no results, returns nil
    assert_nil Parser.parse(xml)
  end
end
