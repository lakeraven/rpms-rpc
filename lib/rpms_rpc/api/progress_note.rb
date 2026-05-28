# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for TIU progress notes — create, list, fetch, edit, lock.
  # Signing lives in {RpmsRpc::ESignature}, not here.
  #
  # Underlying RPCs: TIU CREATE RECORD, TIU DOCUMENTS BY CONTEXT,
  # TIU GET RECORD TEXT, TIU AUTHORIZATION, TIU LOCK RECORD,
  # TIU SET DOCUMENT TEXT, TIU UNLOCK RECORD.
  module ProgressNote
    extend self

    # Wire context codes for TIU DOCUMENTS BY CONTEXT are best-effort
    # placeholders pending wider trace capture; if the codes change, only
    # this table needs updating. Public API uses symbols.
    CONTEXT_CODES = {
      all: "1",
      by_author: "2",
      by_visit: "3",
      unsigned: "4"
    }.freeze

    def create(dfn, visit_ien, title_ien)
      return failure if invalid_id?(dfn) || invalid_id?(visit_ien) || invalid_id?(title_ien)

      raw = DataMapper.tiu_create_record.fetch_scalar(dfn.to_s, visit_ien.to_s, title_ien.to_s)
      success_with_ien(raw)
    end

    def list(dfn, context: :all)
      return [] if invalid_id?(dfn)

      code = CONTEXT_CODES[context]
      raise ArgumentError, "unknown context: #{context.inspect}" if code.nil?

      Array(DataMapper.tiu_documents_by_context.fetch_many(dfn.to_s, code))
    end

    def fetch_text(note_ien)
      return nil if invalid_id?(note_ien)

      DataMapper.tiu_get_record_text.fetch_text(note_ien.to_s)
    end

    def authorize(note_ien, user_duz)
      return false if invalid_id?(note_ien) || invalid_id?(user_duz)

      DataMapper.tiu_authorization.fetch_scalar(note_ien.to_s, user_duz.to_s) == true
    end

    def lock(note_ien, user_duz)
      return false if invalid_id?(note_ien) || invalid_id?(user_duz)

      DataMapper.tiu_lock_record.fetch_scalar(note_ien.to_s, user_duz.to_s) == true
    end

    def update_text(note_ien, text)
      return failure if invalid_id?(note_ien) || text.nil?

      raw = DataMapper.tiu_set_document_text.fetch_scalar(note_ien.to_s, text.to_s)
      {
        success: raw.to_s == "0" || raw.to_s.match?(/\A\d+\z/),
        raw: raw
      }
    end

    def unlock(note_ien, user_duz)
      return false if invalid_id?(note_ien) || invalid_id?(user_duz)

      DataMapper.tiu_unlock_record.fetch_scalar(note_ien.to_s, user_duz.to_s) == true
    end

    private

    def success_with_ien(raw)
      saved_ien = raw.to_s.match(/\A\d+/)&.to_s&.to_i
      {
        success: !saved_ien.nil? && saved_ien.positive?,
        ien: saved_ien,
        raw: raw
      }
    end

    def failure
      { success: false, ien: nil, raw: nil }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
