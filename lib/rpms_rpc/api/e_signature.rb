# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for TIU e-signature. Server validates the signature code
  # against the user's stored hash via ORWU VALIDSIG, then the actual
  # sign/remove action goes through TIU SIGN RECORD.
  #
  # The underlying RPMS layer emits ESIG.ADD / ESIG.DELETE audit events
  # automatically; nothing in this module needs to publish them.
  module ESignature
    extend self

    # Wire action codes for TIU SIGN RECORD are best-effort placeholders
    # pending wider trace capture; the public API uses symbols.
    ACTION_CODES = {
      sign: "S",
      cosign: "C",
      addend: "A"
    }.freeze

    REMOVE_CODE = "D"

    def validate(user_duz, signature_code)
      return false if invalid_id?(user_duz) || blank?(signature_code)

      DataMapper.tiu_valid_signature.fetch_scalar(user_duz.to_s, signature_code.to_s) == true
    end

    # Server-side authoritative answer for which signing action a given user
    # is allowed to perform on a given note. Returns a symbol from
    # ACTION_CODES (or `nil` if the server says no action is permitted /
    # the user has no role on this note).
    def which_action(note_ien, user_duz)
      return nil if invalid_id?(note_ien) || invalid_id?(user_duz)

      code = DataMapper.tiu_which_signature_action.fetch_scalar(note_ien.to_s, user_duz.to_s)
      return nil if code.nil? || code.to_s.strip.empty?

      ACTION_CODES.invert[code.to_s.upcase]
    end

    def add(note_ien, user_duz, signature_code, action: :sign)
      return failure if invalid_id?(note_ien) || invalid_id?(user_duz) || blank?(signature_code)

      code = ACTION_CODES[action]
      raise ArgumentError, "unknown action: #{action.inspect}" if code.nil?

      raw = DataMapper.tiu_sign_record.fetch_scalar(
        note_ien.to_s, user_duz.to_s, signature_code.to_s, code
      )
      result_shape(raw)
    end

    def remove(note_ien, user_duz, reason:)
      return failure if invalid_id?(note_ien) || invalid_id?(user_duz) || blank?(reason)

      # Action code stays at position 3 across all sign/cosign/addend/remove
      # calls so the wire layout is positionally consistent. For remove the
      # reason replaces the signature-code slot at position 2.
      raw = DataMapper.tiu_sign_record.fetch_scalar(
        note_ien.to_s, user_duz.to_s, reason.to_s, REMOVE_CODE
      )
      result_shape(raw)
    end

    private

    def result_shape(raw)
      {
        success: raw.to_s.match?(/\A\d+\z/),
        raw: raw
      }
    end

    def failure
      { success: false, raw: nil }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
