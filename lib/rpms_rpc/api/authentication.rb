# frozen_string_literal: true

require_relative "../mappings"
require_relative "../xwb_cipher"

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

    # Sign on with an access/verify pair.
    #
    # The pair crosses the wire ENCRYPTED. XUSRB.VALIDAV always runs
    # $$DECRYP^XUSRB1 on its parameter, so a cleartext send reaches the broker
    # as garbage and a real RPMS rejects correct credentials (rpms-rpc#200).
    # The ciphertext goes as ONE parameter because it may contain "^".
    #
    # The whole sequence — SIGNON SETUP, AV CODE, and the user/key lookups it
    # implies — runs under the client's wire lock. The broker session these
    # RPCs read from is process-global state, so a second sign-on landing
    # between this one's AV CODE and its user lookup would hand this caller
    # the other clinician's name, role and security keys.
    def authenticate(access_code: nil, verify_code: nil)
      return validation_error("Access code is required") if blank?(access_code&.to_s&.strip)
      return validation_error("Verify code is required") if blank?(verify_code&.to_s&.strip)

      av_code = "#{normalize_code(access_code)};#{normalize_code(verify_code)}"

      with_wire_lock do
        signon_setup
        parse_auth_response(DataMapper.av_code.fetch_lines(XwbCipher.encrypt(av_code)))
      end
    end

    def user_info(duz)
      return nil if invalid_id?(duz)

      # XUS GET USER INFO returns the authenticated session user's info
      # and takes no params; the duz arg is validated here only as an
      # API guard, not passed to the broker.
      info = DataMapper.user_info.fetch_lines
      return nil if info.nil? || info[:duz].to_i != duz.to_i

      info
    end

    def has_security_key?(duz, key_name)
      return false if invalid_id?(duz) || blank_after_strip?(key_name)

      DataMapper.user_has_key.fetch_scalar(duz.to_s, key_name.to_s) == true
    end

    def user_security_keys(duz)
      return [] if invalid_id?(duz)
      return [] unless RpmsRpc.client.supports?(:user_security_keys_list)

      Array(DataMapper.user_keys.fetch_many(duz.to_s)).filter_map { |row| presence(row[:key_name]) }
    end

    def change_verify_code(old_verify_code:, new_verify_code:, confirm_verify_code:, **_unused_keywords)
      return validation_error("Old verify code is required") if blank?(old_verify_code&.to_s&.strip)
      return validation_error("New verify code is required") if blank?(new_verify_code&.to_s&.strip)
      if blank?(confirm_verify_code&.to_s&.strip)
        return validation_error("Confirm verify code is required")
      end

      # CVC^XUSRB does NOT decrypt the way VALIDAV does. Read the M
      # (XUSRB.m:70-71): it SPLITS ON "^" FIRST, then decrypts each piece.
      #
      #   S U="^",XU2=$P(XU1,U,2),XU3=$P(XU1,U,3),XU1=$P(XU1,U)
      #   S XU1=$$DECRYP^XUSRB1(XU1),XU2=$$DECRYP^XUSRB1(XU2),XU3=$$DECRYP^XUSRB1(XU3)
      #
      # So each component is encrypted SEPARATELY and the ciphertexts are
      # joined with "^". Encrypting the whole triple as one value puts the
      # delimiter inside the ciphertext and the server decrypts three
      # fragments of garbage. (This framing is safe because the cipher table
      # deliberately omits "^" — see XwbCipher::TABLE — and verify codes
      # exclude it too, per AVHLPTXT^XUS2.)
      cvc_param = [
        normalize_code(old_verify_code),
        normalize_code(new_verify_code),
        normalize_code(confirm_verify_code)
      ].map { |component| XwbCipher.encrypt(component) }.join("^")

      parsed = with_wire_lock { DataMapper.cvc_verify.fetch_lines(cvc_param) }
      # `parsed&.dig(:result_code).to_i.zero?` was previously true for nil
      # responses (`nil.to_i == 0`), masking timeouts / RPC drops as success.
      # Require an explicit present `result_code` that equals `"0"`.
      code = parsed && parsed[:result_code]
      if code.to_s == "0"
        { success: true }
      else
        validation_error("Verify code change failed")
      end
    end

    def clear_cache!
      @signon_setup_cache = nil
    end

    private

    # Run a multi-RPC sequence as one uninterruptible unit on the shared
    # client. Reentrant, so nested calls that take the lock themselves are
    # safe. Clients that predate the lock (or stand in for one) just yield.
    def with_wire_lock(&block)
      client = RpmsRpc.client
      return yield unless client.respond_to?(:synchronize_wire)

      client.synchronize_wire(&block)
    end

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
      return true if blank?(value)
      return false if value.is_a?(Integer) && value.positive?

      # Strict-digit guard: prevents inputs like "301abc" from sneaking
      # past to_i (which would return 301 and accidentally match the
      # session user via user_info's post-fetch duz comparison).
      !value.to_s.strip.match?(/\A[1-9]\d*\z/)
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
