# frozen_string_literal: true

require_relative "../mappings"
require_relative "../xwb_cipher"

module RpmsRpc
  # Symbolic API for TIU e-signature. Server validates the signature code
  # against the user's stored hash via ORWU VALIDSIG, then the actual
  # sign action goes through TIU SIGN RECORD.
  #
  # Wire contract (verified against the M source + RPC registry, file 8994):
  #
  #   ORWU VALIDSIG            VALIDSIG(ESOK,X)^ORWU
  #     One wire param: the signature code encrypted with the XWB cipher
  #     (server runs $$DECRYP^XUSRB1, compares to ^VA(200,DUZ,20) piece 4).
  #     The user is the session DUZ — never sent as a param.
  #
  #   TIU SIGN RECORD          SIGN(ERR,TIUDA,TIUX)^TIUSRVP
  #     Two wire params: (1) TIUDA — note IEN, (2) TIUX — the signature
  #     code, encrypted with the same XWB cipher. The signer is the
  #     session DUZ; whether that comes out as signature or cosignature
  #     is decided server-side. There is NO action-code param.
  #
  #   TIU WHICH SIGNATURE ACTION   WHATACT(TIUY,TIUDA)^TIUSRVA
  #     One wire param: TIUDA. Returns the string "SIGNATURE" or
  #     "COSIGNATURE" (empty when the session user has no signing role).
  #
  #   TIU DELETE RECORD        DELETE(ERR,TIUDA,TIURSN,OVRRIDE)^TIUSRVP
  #     Signature removal is NOT a TIU SIGN RECORD action code — TIU's
  #     model of retracting a (signed) note is deleting the document.
  #     Wire params: TIUDA, deletion reason, override flag.
  #
  # `user_duz` args are retained across the public Ruby API for caller
  # compatibility (the lakeraven-ehr ESignatureGateway passes them), but the
  # DUZ rides the authenticated broker session and is never sent on the wire.
  #
  # The underlying RPMS layer emits ESIG.ADD / ESIG.DELETE audit events
  # automatically; nothing in this module needs to publish them.
  module ESignature
    extend self

    # WHATACT^TIUSRVA return strings → public API symbols.
    ACTIONS = {
      "SIGNATURE" => :sign,
      "COSIGNATURE" => :cosign
    }.freeze

    # Validate `signature_code` for the session user. `user_duz` is accepted
    # for API compatibility but not sent — the server checks against the
    # session DUZ's stored signature hash.
    def validate(user_duz, signature_code)
      return false if invalid_id?(user_duz) || blank?(signature_code)

      DataMapper.tiu_valid_signature.fetch_scalar(
        XwbCipher.encrypt(signature_code.to_s)
      ) == true
    end

    # Server-side authoritative answer for which signing action the session
    # user may perform on a given note. Returns :sign, :cosign, or nil (no
    # action permitted / no role on this note). `user_duz` is accepted for
    # API compatibility but not sent — WHATACT^TIUSRVA uses the session DUZ.
    def which_action(note_ien, user_duz)
      return nil if invalid_id?(note_ien) || invalid_id?(user_duz)

      raw = DataMapper.tiu_which_signature_action.fetch_scalar(note_ien.to_s)
      return nil if raw.nil? || raw.to_s.strip.empty?

      ACTIONS[raw.to_s.strip.upcase]
    end

    # Sign (or cosign) a note. Sends exactly two wire params — the note IEN
    # and the XWB-encrypted signature code. `user_duz` is accepted for API
    # compatibility but not sent; sign-vs-cosign is decided server-side, so
    # `action:` is validated (:sign / :cosign) but also never sent.
    def add(note_ien, user_duz, signature_code, action: :sign)
      unless ACTIONS.value?(action)
        raise ArgumentError, "unknown action: #{action.inspect} — the server " \
                             "decides sign vs cosign; addenda go through a " \
                             "separate TIU RPC, not TIU SIGN RECORD"
      end
      return failure if invalid_id?(note_ien) || invalid_id?(user_duz) || blank?(signature_code)

      raw = DataMapper.tiu_sign_record.fetch_scalar(
        note_ien.to_s, XwbCipher.encrypt(signature_code.to_s)
      )
      result_shape(raw)
    end

    # Retract a note. TIU has no "remove signature" action — retraction is
    # document deletion via TIU DELETE RECORD (TIUDA, reason, override flag).
    # `user_duz` is accepted for API compatibility but not sent.
    def remove(note_ien, user_duz, reason:, override: false)
      return failure if invalid_id?(note_ien) || invalid_id?(user_duz) || blank?(reason)

      raw = DataMapper.tiu_delete_record.fetch_scalar(
        note_ien.to_s, reason.to_s, override ? "1" : "0"
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
