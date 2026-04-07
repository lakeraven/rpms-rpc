# frozen_string_literal: true

require "rexml/document"

# Parses XML responses from VistA RPC calls.
#
# VistA RPC Broker returns XML in two shapes:
# - Normal: <vistalink type="Gov.VA.Med.RPC.Response"><results type="string|array">
# - Error:  <vistalink type="VA.RPC.Error"><errors><error>
module RpmsRpc
  class XmlResponseParser
    class RpcError < StandardError
      attr_accessor :code
    end

    class ParseError < StandardError; end

    def self.parse(xml_string)
      raise ParseError, "XML string cannot be nil" if xml_string.nil?
      raise ParseError, "XML string cannot be empty" if xml_string.empty?

      begin
        doc = REXML::Document.new(xml_string)
      rescue REXML::ParseException => e
        raise ParseError, "Malformed XML: #{e.message}"
      end

      root = doc.root
      return nil unless root

      vistalink_type = root.attributes["type"]
      if vistalink_type&.include?("Error")
        parse_error_response(root)
      else
        parse_normal_response(root)
      end
    end

    def self.parse_normal_response(vistalink_element)
      results_element = vistalink_element.elements["results"]
      return nil unless results_element

      result_type = results_element.attributes["type"]
      cdata_content = extract_cdata(results_element)

      case result_type
      when "string"
        cdata_content || ""
      when "array"
        parse_array_content(cdata_content)
      else
        cdata_content
      end
    end

    def self.parse_error_response(vistalink_element)
      errors_element = vistalink_element.elements["errors"]
      return nil unless errors_element

      error_element = errors_element.elements["error"]
      if error_element
        error_code = error_element.attributes["code"]&.to_i
        msg_element = error_element.elements["msg"]
        error_message = msg_element&.text || "Unknown error"

        error = RpcError.new(error_message)
        error.code = error_code
        raise error
      end

      raise RpcError, "Unknown RPC error"
    end

    def self.extract_cdata(element)
      cdata = element.cdatas.first
      return cdata.value if cdata

      element.text
    end

    def self.parse_array_content(content)
      return [] if content.nil? || content.empty?

      lines = content.split("\n")
      lines.shift if lines.first == "" # Remove leading empty line if present
      lines
    end
  end
end
