# frozen_string_literal: true

# Encodes parameters for VistA RPC calls.
#
# Implements the VistA RPC Broker parameter encoding protocol.
# Format: 1{len}00f{value}\x04
#   1     = type indicator (string)
#   {len} = 3-digit zero-padded byte length
#   00f   = flags/format
#   {value} = actual value
#   \x04  = EOT terminator
module RpmsRpc
  class ParameterEncoder
    class ParameterTooLongError < StandardError; end

    EOT = "\x04"
    MAX_PARAM_LENGTH = 999

    def self.encode(param)
      value = case param
      when nil   then ""
      when true  then "true"
      when false then "false"
      when Array then param.map(&:to_s).join("\n")
      else param.to_s
      end

      byte_size = value.bytesize
      if byte_size > MAX_PARAM_LENGTH
        raise ParameterTooLongError, "Parameter too long (#{byte_size} > #{MAX_PARAM_LENGTH})"
      end

      "1#{format('%03d', byte_size)}00f#{value}#{EOT}"
    end

    def self.encode_list(params)
      return "" if params.nil? || params.empty?

      params.map { |p| encode(p) }.join
    end

    def self.encode_hash(hash)
      lines = hash.map { |k, v| "#{k}=#{v}" }
      encode(lines.join("\n"))
    end

    # Decode parameter from RPC format: 1{len}00f{value}\x04
    def self.decode(encoded_str)
      return "" if encoded_str.nil? || encoded_str.empty?

      if encoded_str.start_with?("1") && encoded_str.include?(EOT)
        value_start = 7
        eot_position = encoded_str.index(EOT)
        return encoded_str[value_start...eot_position] if eot_position
      end

      encoded_str
    end
  end
end
