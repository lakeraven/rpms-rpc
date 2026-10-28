# frozen_string_literal: true

require_relative "xwb_cipher"
require_relative "mappings"

module RpmsRpc
  # ORWU VALIDSIG (VALIDSIG(ESOK,X)^ORWU). One wire parameter: the
  # signature code encrypted with the XWB cipher. The user is the session
  # DUZ and is never sent. ESignature.validate and Order.sign_and_release
  # both come through here so the ciphertext and the reply read cannot
  # drift. Encryption picks a random row pair, so a caller that must send
  # the same ES again (ORWDX SEND) keeps the string #encrypt returned.
  module ValidSignature
    class << self
      def encrypt(signature_code)
        XwbCipher.encrypt(signature_code.to_s)
      end

      # The scalar reply line, or nil when the broker returned nothing.
      # Trailing $C(30)/$C(31) are stripped the way a DataMapper scalar
      # strips them. The line is not coerced: "1" is VALIDSIG's success
      # token, and ESignature.accepted? also allows the mapper's "yes".
      def line_for(encrypted)
        response = RpmsRpc.client.call_rpc(DataMapper.tiu_valid_signature.rpc_name, encrypted)
        scalar_line(response)
      end

      # DataMapper :boolean (data_mapper.rb coerce): exact "1", or "yes"
      # in any case. Empty and nil are not valid.
      def accepted?(line)
        return false if line.nil? || line.empty?

        line == "1" || line.casecmp?("yes")
      end

      private

      def scalar_line(response)
        return nil if response.nil?
        return nil if response.is_a?(String) && response.empty?

        line = if response.is_a?(Array)
          response.lazy
                  .map { |row| DataMapper.strip_recordset_separators(row) }
                  .reject { |row| row.empty? || DataMapper.recordset_header_row?(row) }
                  .first
        else
          DataMapper.strip_recordset_separators(response)
        end
        return nil if line.nil? || line.empty?

        line
      end
    end
  end
end
