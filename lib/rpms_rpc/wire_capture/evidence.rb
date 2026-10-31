# frozen_string_literal: true

module RpmsRpc
  module WireCapture
    # Whether a mapped or wire token is real evidence of a field.
    #
    # Empty strings and masked or pseudo placeholders are not real. +false+
    # and +0+ are real values, not absence. An Array is real when any
    # element is. Placeholder shapes live in PLACEHOLDER_PATTERNS.
    module Evidence
      PLACEHOLDER_PATTERNS = [
        /\AXXX-XX-(?:XXXX|\d{4})\z/i,
        /\*\*.*?\*\*/,
        /\A\*+\z/,
        /\A-+\z/,
        /\A000-00-0000\z/,
        /\A<none>\z/i
      ].freeze

      module_function

      def real_value?(value)
        return value.any? { |element| real_value?(element) } if value.is_a?(Array)
        return true if value == false || value == 0

        text = value.to_s.strip
        return false if text.empty?

        PLACEHOLDER_PATTERNS.none? { |pattern| pattern.match?(text) }
      end
    end
  end
end
