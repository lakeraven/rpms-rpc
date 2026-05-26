# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for VistA/RPMS authentication RPCs.
  # Underlying RPCs: XUS SIGNON SETUP, XUS AV CODE, XUS CVC,
  # XUS GET USER INFO, ORWU HASKEY, ORWU USERKEYS.
  module Authentication
    extend self

    ERROR_MESSAGES = {
      0 => nil,
      1 => "Invalid access/verify code",
      2 => "Logins inhibited",
      3 => "Account locked",
      4 => "Authentication failure",
      5 => "Other error",
      7 => "IP address locked (three-strike lockout)",
      12 => "Verify code expired - must be changed"
    }.freeze

    USER_TYPES = {
      3 => "provider",
      4 => "nurse",
      5 => "clerk"
    }.freeze

    def authenticate(access_code: nil, verify_code: nil)
      return validation_error("Access code is required") if blank?(access_code&.to_s&.strip)
      return validation_error("Verify code is required") if blank?(verify_code&.to_s&.strip)

      signon_setup
      av_code = "#{normalize_code(access_code)};#{normalize_code(verify_code)}"
      parsed = DataMapper.av_code.fetch_lines(av_code)

      parse_auth_response(parsed)
    end

    def user_info(duz)
      return nil if invalid_id?(duz)

      DataMapper.user_info.fetch_one(duz.to_s)
    end

    def has_security_key?(duz, key_name)
      return false if invalid_id?(duz) || blank_after_strip?(key_name)

      DataMapper.user_has_key.fetch_scalar(duz.to_s, key_name.to_s) == true
    end

    def user_security_keys(duz)
      return [] if invalid_id?(duz)

      Array(DataMapper.user_keys.fetch_many(duz.to_s)).filter_map { |row| presence(row[:key_name]) }
    end

    def change_verify_code(old_verify_code:, new_verify_code:, confirm_verify_code:, **_unused_keywords)
      return validation_error("Old verify code is required") if blank?(old_verify_code&.to_s&.strip)
      return validation_error("New verify code is required") if blank?(new_verify_code&.to_s&.strip)
      if blank?(confirm_verify_code&.to_s&.strip)
        return validation_error("Confirm verify code is required")
      end

      cvc_param = [
        normalize_code(old_verify_code),
        normalize_code(new_verify_code),
        normalize_code(confirm_verify_code)
      ].join("^")

      parsed = DataMapper.cvc_verify.fetch_lines(cvc_param)
      parsed&.dig(:result_code).to_i.zero? ? { success: true } : validation_error("Verify code change failed")
    end

    def clear_cache!
      @signon_setup_cache = nil
    end

    private

    def signon_setup
      @signon_setup_cache ||= DataMapper.signon_setup.fetch_scalar
    end

    def parse_auth_response(parsed)
      return validation_error("Invalid response") if parsed.nil? || parsed.empty?

      duz = parsed[:duz].to_i
      error_code = parsed[:error_code].to_i
      verify_needs_change = parsed[:verify_needs_change].to_i == 1
      message = parsed[:message].to_s

      if duz.positive? && error_code.zero?
        auth_success(duz, parsed[:user_class], message, verify_needs_change)
      else
        {
          success: false,
          duz: duz.positive? ? duz : nil,
          error: ERROR_MESSAGES[error_code] || presence(message) || "Authentication failed",
          error_code: error_code,
          verify_needs_change: error_code == 12
        }
      end
    end

    def auth_success(duz, user_class, message, verify_needs_change)
      result = {
        success: true,
        duz: duz,
        provider_ien: duz,
        message: message,
        verify_needs_change: verify_needs_change,
        user_type: USER_TYPES.fetch(user_class.to_i, "user")
      }

      info = user_info(duz)
      result[:name] = info[:name] if info
      result
    end

    def validation_error(message)
      { success: false, error: message }
    end

    def normalize_code(code)
      code.to_s.strip.upcase
    end

    def invalid_id?(value)
      blank?(value) || value.to_i <= 0
    end

    def presence(value)
      return nil if value.nil?

      str = value.to_s
      str.empty? ? nil : str
    end

    def blank?(value)
      value.nil? || value.to_s.empty?
    end

    def blank_after_strip?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
