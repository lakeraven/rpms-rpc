# frozen_string_literal: true

require "openssl"

# HIPAA-aligned PHI sanitization for logs and error messages.
#
# Provides methods to hash or redact Protected Health Information (PHI)
# before logging or displaying in error messages. Used by lakeraven-ehr
# and any host that wants to sanitize PHI from logs.
#
# Standalone module with zero Rails dependencies (Rails is detected
# optionally for secret_key_base).
#
# Usage:
#   RpmsRpc::PhiSanitizer.hash_identifier("12345")
#   RpmsRpc::PhiSanitizer.sanitize_hash({ patient_dfn: "12345" })
#   RpmsRpc::PhiSanitizer.sanitize_message("Error for DFN: 12345")
module RpmsRpc
  module PhiSanitizer
    extend self

    PHI_FIELDS = %i[
      patient_dfn dfn ssn social_security_number dob date_of_birth born_on
      tribal_enrollment_number policy_number group_number mbi medicare_id
      medicaid_id va_id
    ].freeze

    REDACT_FIELDS = %i[ssn social_security_number].freeze

    attr_writer :secret_key

    # Hash a PHI identifier to a 12-char HMAC-SHA256 prefix.
    def hash_identifier(identifier)
      return nil if identifier.nil? || identifier.to_s.empty?

      digest = OpenSSL::HMAC.hexdigest("SHA256", resolve_secret_key, identifier.to_s)
      digest[0..11]
    end

    # Sanitize a hash by hashing/redacting PHI fields.
    def sanitize_hash(data)
      return {} if data.nil?

      data.transform_keys(&:to_sym).each_with_object({}) do |(key, value), result|
        result[sanitized_key(key)] = sanitize_value(key, value)
      end
    end

    # Sanitize a string that may contain PHI.
    def sanitize_message(message)
      return "" if message.nil? || message.to_s.empty?

      sanitized = message.dup

      # Patient names: "patient: SMITH,JOHN" or "patient_name: JONES,MARY"
      sanitized.gsub!(
        /\bpatient[_\s]*(?:name)?[:\s]+([A-Z]+(?:\s+JR|SR|II|III|IV)?),\s*([A-Z]+(?:\s+[A-Z]+)*)/i,
        "patient:[NAME-REDACTED]"
      )

      # Standalone VistA-format names (LASTNAME,FIRSTNAME)
      sanitized.gsub!(/\b([A-Z]{2,}),\s*([A-Z]{2,}(?:\s+[A-Z]{2,})*)\b/) do |_match|
        "[NAME-REDACTED]"
      end

      # DFN/IEN/HRN identifiers
      sanitized.gsub!(/\bDFN[:\s]*\d+/i, "DFN:[REDACTED]")
      sanitized.gsub!(/\bpatient[_\s]*dfn[:\s]*\d+/i, "patient_dfn:[REDACTED]")
      sanitized.gsub!(/\bpatient[_\s]*IEN[:\s]*\d+/i, "patient_IEN:[REDACTED]")
      sanitized.gsub!(/\bHRN[:\s]*\d+/i, "HRN:[HRN-REDACTED]")
      sanitized.gsub!(/\bhealth[_\s]*record[_\s]*(?:number)?[:\s]*\d+/i, "health_record:[HRN-REDACTED]")

      # SSN (with dashes, then bare 9-digit numbers)
      sanitized.gsub!(/\b\d{3}-\d{2}-\d{4}\b/, "[SSN-REDACTED]")
      sanitized.gsub!(/\b\d{9}\b/, "[ID-REDACTED]")

      # Birth/death dates
      sanitized.gsub!(/\b(dob|birth[_\s]*date)[:\s]*\d{4}-\d{2}-\d{2}/i, '\1:[DATE-REDACTED]')
      sanitized.gsub!(/\b(death[_\s]*date|deceased)[:\s]*\d{4}-\d{2}-\d{2}/i, '\1:[DATE-REDACTED]')

      # Phone numbers
      sanitized.gsub!(/\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b/, "[PHONE-REDACTED]")

      sanitized
    end

    # Return a PHI-safe context hash for logging.
    def safe_patient_context(patient_dfn)
      { patient_id_hash: hash_identifier(patient_dfn) }
    end

    private

    def resolve_secret_key
      @secret_key || rails_secret_key || "development-fallback-key"
    end

    def rails_secret_key
      return nil unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

      Rails.application.secret_key_base
    end

    def sanitized_key(key)
      case key
      when :patient_dfn, :dfn         then :patient_id_hash
      when :ssn, :social_security_number then :ssn_present
      else key
      end
    end

    def sanitize_value(key, value)
      sym_key = key.to_sym

      if REDACT_FIELDS.include?(sym_key)
        !(value.nil? || value.to_s.empty?)
      elsif PHI_FIELDS.include?(sym_key)
        hash_identifier(value)
      elsif value.is_a?(Hash)
        sanitize_hash(value)
      else
        value
      end
    end
  end
end
