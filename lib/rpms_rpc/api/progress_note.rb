# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for TIU progress notes — create, list, fetch, edit, lock.
  # Signing lives in {RpmsRpc::ESignature}, not here.
  #
  # Underlying RPCs: TIU CREATE RECORD, TIU DOCUMENTS BY CONTEXT,
  # TIU GET RECORD TEXT, TIU AUTHORIZATION, TIU LOCK RECORD,
  # TIU SET DOCUMENT TEXT, TIU UNLOCK RECORD.
  #
  # Each call sends the actuals its routine declares (Text Integration
  # Utility/Routines in the FOIA source) and reads the reply the way the
  # routine writes it (#219). The replies are status strings, not
  # booleans: LOCK answers 0 when it HOLDS the lock.
  module ProgressNote
    extend self

    # CLASS for CONTEXT^TIUSRVLO: the TIU DOCUMENT DEFINITION (#8925.1)
    # NOTES^TIUSRVLO lists progress notes under (TIUSRVLO.m:8).
    PROGRESS_NOTES_CLASS = "3"

    # CONTEXT codes as CONTEXT^TIUSRVLO documents them (TIUSRVLO.m:19-23).
    CONTEXT_CODES = {
      all_signed: "1",            # signed, by patient
      unsigned: "2",              # unsigned, by patient and author/transcriber
      uncosigned: "3",            # uncosigned, by patient and expected cosigner
      signed_by_author: "4",      # signed, by patient and author
      signed_by_date_range: "5"   # signed, by patient and date range
    }.freeze

    # The TIUACT CANDO^TIUSRVA compares against (TIUSRVA.m:23-24).
    EDIT_RECORD = "EDIT RECORD"

    # MAKE(SUCCESS,DFN,TITLE,VDT,VLOC,VSIT,TIUX,VSTR,SUPPRESS,NOASF)
    # (TIUSRVP.m:7). The visit goes in VSIT; MAKE builds the visit string
    # and date from it (TIUSRVP.m:24-31), so VDT and VLOC go empty.
    # SUCCESS is the new IEN (TIUSRVP.m:61) or "0^message" (TIUSRVP.m:58, 60).
    def create(dfn, visit_ien, title_ien)
      return failure if invalid_id?(dfn) || invalid_id?(visit_ien) || invalid_id?(title_ien)

      raw = DataMapper.tiu_create_record.fetch_scalar(dfn.to_s, title_ien.to_s, "", "", visit_ien.to_s)
      success_with_ien(raw)
    end

    # CONTEXT(TIUY,CLASS,CONTEXT,DFN,EARLY,LATE,PERSON,...) (TIUSRVLO.m:16).
    # PERSON narrows contexts 2-4 and defaults to the signed-on user;
    # EARLY/LATE bound context 5 (TIUSRVLO.m:25-27, 38-42). Each row's
    # author arrives as DUZ;SIGNATURE NAME;NAME (TIUSRVLO.m:195) and is
    # split into :author_duz and :author_name.
    def list(dfn, context: :all_signed, early: nil, late: nil, person: nil)
      return [] if invalid_id?(dfn)

      code = CONTEXT_CODES[context]
      raise ArgumentError, "unknown context: #{context.inspect}" if code.nil?

      params = [ PROGRESS_NOTES_CLASS, code, dfn.to_s, early.to_s, late.to_s, person.to_s ]
      params.pop while params.last.empty?
      Array(DataMapper.tiu_documents_by_context.fetch_many(*params)).map { |row| with_author(row) }
    end

    def fetch_text(note_ien)
      return nil if invalid_id?(note_ien)

      DataMapper.tiu_get_record_text.fetch_text(note_ien.to_s)
    end

    # CANDO(TIUY,TIUDA,TIUACT) (TIUSRVA.m:20): may the signed-on user take
    # +action+ on the note? 1 is yes (TIUSRVA.m:30); "0^reason" is no
    # (TIUSRVA.m:23, 26, 29).
    def authorize(note_ien, action: EDIT_RECORD)
      return false if invalid_id?(note_ien)

      raw = DataMapper.tiu_authorization.fetch_scalar(note_ien.to_s, action.to_s)
      first_piece(raw) == "1"
    end

    # LOCK(ERR,TIUDA) (TIUSRVP.m:210): true when the lock is held (ERR=0,
    # TIUSRVP.m:211), false on "1^ Another session has this record
    # locked." (TIUSRVP.m:212).
    def lock(note_ien)
      return false if invalid_id?(note_ien)

      first_piece(DataMapper.tiu_lock_record.fetch_scalar(note_ien.to_s)) == "0"
    end

    # SETTEXT(TIUY,TIUDA,TIUX,SUPPRESS) (TIUSRVPT.m:7) reads TIUX as a list:
    # PAGE^PAGES from TIUX("HDR") (TIUSRVPT.m:12) and the body from
    # TIUX("TEXT",n,0) (TIUSRVPT.m:18). The text goes as one page. Success
    # is the TIUDA^PAGE^PAGES acknowledgement (TIUSRVPT.m:38); failure is
    # "0^0^0^message" (TIUSRVPT.m:10, 14).
    #
    # Update returns a 2-key {success:, raw:} shape rather than the
    # create/sign-style 3-key {success:, ien:, raw:} — there's no new IEN
    # to surface, and an :ien key on an update would mislead callers.
    def update_text(note_ien, text)
      return update_failure if invalid_id?(note_ien) || text.nil?

      raw = DataMapper.tiu_set_document_text.fetch_scalar(note_ien.to_s, text_list(text))
      { success: first_piece(raw) == note_ien.to_i.to_s, raw: raw }
    end

    # UNLOCK(ERR,TIUDA) (TIUSRVP.m:214-215): always ERR=0.
    def unlock(note_ien)
      return false if invalid_id?(note_ien)

      first_piece(DataMapper.tiu_unlock_record.fetch_scalar(note_ien.to_s)) == "0"
    end

    private

    def text_list(text)
      lines = text.to_s.split(/\r?\n/, -1)
      lines.pop if lines.length > 1 && lines.last.empty?
      lines.each_with_index.with_object({ "HDR" => "1^1" }) do |(line, i), tiux|
        tiux[[ "TEXT", i + 1, 0 ]] = line
      end
    end

    def with_author(row)
      duz, _signature, name = row[:author].to_s.split(";", 3)
      row.merge(author_duz: duz.to_s.empty? ? nil : duz, author_name: name)
    end

    def first_piece(raw)
      raw.to_s.split("^", 2).first.to_s
    end

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

    def update_failure
      { success: false, raw: nil }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
