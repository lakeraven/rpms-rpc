# frozen_string_literal: true

require_relative "../shape"
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
    extend Shape::Declarable

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

    # Bytes. update_text wraps a longer line at this width unless the
    # caller passes wrap_width: (an Integer from 4 to 999). #479.
    WRAP_WIDTH = 80

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
    shape :list, resource: "progress-notes", verb: "GET", path: "/patients/{dfn}/progress-notes"

    def fetch_text(note_ien)
      return nil if invalid_id?(note_ien)

      DataMapper.tiu_get_record_text.fetch_text(note_ien.to_s)
    end
    shape :fetch_text, resource: "progress-notes", verb: "GET", path: "/progress-notes/{note_ien}/text"

    # CANDO(TIUY,TIUDA,TIUACT) (TIUSRVA.m:20): may the signed-on user take
    # +action+ on the note? 1 is yes (TIUSRVA.m:30); "0^reason" is no
    # (TIUSRVA.m:23, 26, 29).
    def authorize(note_ien, action: EDIT_RECORD)
      return false if invalid_id?(note_ien)

      raw = DataMapper.tiu_authorization.fetch_scalar(note_ien.to_s, action.to_s)
      first_piece(raw) == "1"
    end
    shape :authorize, resource: "progress-notes", verb: "GET", path: "/progress-notes/{note_ien}/authorize"

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
    # A line longer than wrap_width bytes (default WRAP_WIDTH, 80) is cut
    # into consecutive pieces. The cut is the last space or tab whose byte
    # offset is within the width and past the leading indentation; that one
    # whitespace character is dropped. With no such break, the cut is the
    # last UTF-8 character boundary within the width and nothing is dropped.
    # Lines that fit, including blank lines, are unchanged. This changes how
    # the note is laid out in the chart.
    #
    # Rejoining the pieces with the dropped character restores the line.
    # Joined with a single space, a tab at a cut reads back as a space, and
    # a space or tab cut at the very end of a line is dropped. Non-whitespace
    # is never dropped or changed. Indentation is not repeated on continuation
    # pieces; an indent wider than the width is itself hard-cut.
    #
    # Text is coerced with to_s, then refused (nothing is sent) unless the
    # result is a String whose encoding is exactly UTF-8, US-ASCII or
    # ASCII-8BIT and whose bytes are valid UTF-8. Any other encoding is
    # refused regardless of content (a Latin-1 or Windows-1252 tag whose
    # bytes happen to be valid UTF-8 would otherwise be filed as different
    # characters), as is a to_s that returns nil or a non-String. Split and
    # wrap run on the validated UTF-8 string, so Encoding::CompatibilityError
    # cannot escape from a mismatched tag.
    #
    # Update returns a 2-key {success:, raw:} shape rather than the
    # create/sign-style 3-key {success:, ien:, raw:} — there's no new IEN
    # to surface, and an :ien key on an update would mislead callers.
    def update_text(note_ien, text, wrap_width: WRAP_WIDTH)
      validate_wrap_width!(wrap_width)
      return update_failure if invalid_id?(note_ien) || text.nil?

      utf8 = utf8_text(text)
      return utf8_failure if utf8.nil?

      raw = DataMapper.tiu_set_document_text.fetch_scalar(note_ien.to_s, text_list(utf8, wrap_width))
      { success: first_piece(raw) == note_ien.to_i.to_s, raw: raw }
    rescue RpmsRpc::Client::FrameTooLongError => e
      # The wire refused a value it would have mis-framed (#472); nothing was
      # sent. Wrapping runs first, so no note line over 999 bytes reaches XWB.
      # Kept for any wire that still refuses a framed value. The hash says the
      # request could not be framed and keeps the wire's message; it never
      # includes the note text. BMX does not reach this rescue: BmxClient#call_rpc
      # raises NotImplementedError for every list or Hash parameter before
      # framing, so update_text on BMX raises for every note and never returns
      # the failure hash. That BMX behaviour predates #479 and is unchanged.
      # update_text is the second call of create-then-update, so a host that
      # already created the note holds an empty one (#480).
      { success: false, raw: nil, error: too_long_reason(e) }
    end

    # UNLOCK(ERR,TIUDA) (TIUSRVP.m:214-215): always ERR=0.
    def unlock(note_ien)
      return false if invalid_id?(note_ien)

      first_piece(DataMapper.tiu_unlock_record.fetch_scalar(note_ien.to_s)) == "0"
    end

    private

    def validate_wrap_width!(wrap_width)
      return if wrap_width.is_a?(Integer) && wrap_width.between?(4, 999)

      raise ArgumentError, "wrap_width must be an Integer from 4 to 999"
    end

    # to_s first. Nil unless the result is a String whose encoding is exactly
    # UTF-8, US-ASCII or ASCII-8BIT and whose bytes are valid UTF-8. Any other
    # encoding is refused before the bytes are re-read: a Latin-1 or
    # Windows-1252 tag whose bytes happen to be valid UTF-8 would otherwise be
    # filed as different characters, and UTF-16 of ASCII force-tagged UTF-8 is
    # valid UTF-8 (embedded NULs). Accepted text is returned tagged UTF-8,
    # bytes unchanged. The note text stays out of the error.
    def utf8_text(value)
      text = value.to_s
      return nil unless text.is_a?(String)
      return nil unless [ Encoding::UTF_8, Encoding::US_ASCII, Encoding::ASCII_8BIT ].include?(text.encoding)

      utf8 = text.encoding == Encoding::UTF_8 ? text : text.dup.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? ? utf8 : nil
    end

    def utf8_failure
      { success: false, raw: nil, error: "note text is not valid UTF-8" }
    end

    def text_lines(text)
      lines = text.to_s.split(/\r?\n/, -1)
      lines.pop if lines.length > 1 && lines.last.empty?
      lines
    end

    # Wrapping already kept each note line within the width, so this is a
    # framed request the wire still refused. The wire's own message is kept.
    # The note text is not.
    def too_long_reason(error)
      "the request could not be framed on this wire (#{error.message})"
    end

    def text_list(text, wrap_width)
      lines = text_lines(text).flat_map { |line| wrap_line(line, wrap_width) }
      lines.each_with_index.with_object({ "HDR" => "1^1" }) do |(line, i), tiux|
        tiux[[ "TEXT", i + 1, 0 ]] = line
      end
    end

    # The first piece keeps any leading spaces or tabs. A later piece is the
    # remainder, so indentation is not copied onto it. An indent wider than
    # the width is hard-cut with the line.
    def wrap_line(line, wrap_width)
      return [ line ] if line.bytesize <= wrap_width

      pieces = []
      rest = line
      while rest.bytesize > wrap_width
        break_at = soft_break_offset(rest, wrap_width)
        if break_at
          pieces << byte_slice(rest, 0, break_at)
          rest = byte_slice(rest, break_at + 1, rest.bytesize - break_at - 1)
        else
          break_at = utf8_boundary_offset(rest, wrap_width)
          pieces << byte_slice(rest, 0, break_at)
          rest = byte_slice(rest, break_at, rest.bytesize - break_at)
        end
      end
      pieces << rest unless rest.empty?
      pieces
    end

    # Last space or tab at a byte offset within the width and past the
    # leading run of spaces and tabs. Nil when the line must be hard-cut.
    # Indentation is scanned only through wrap_width + 1 bytes. A longer run
    # cannot hold a soft break inside the width (the search starts at
    # indent + 1), and scanning the whole run again on every piece is
    # quadratic. The cut is the same as a full scan.
    def soft_break_offset(line, wrap_width)
      indent = leading_indent_bytes(line, wrap_width + 1)
      return nil if indent > wrap_width

      last = nil
      index = indent + 1
      last_index = [ wrap_width, line.bytesize - 1 ].min
      while index <= last_index
        last = index if space_or_tab?(line.getbyte(index))
        index += 1
      end
      last
    end

    def leading_indent_bytes(line, limit)
      index = 0
      max = [ limit, line.bytesize ].min
      index += 1 while index < max && space_or_tab?(line.getbyte(index))
      index
    end

    def space_or_tab?(byte)
      byte == " ".ord || byte == "\t".ord
    end

    # Largest UTF-8 character boundary at or before wrap_width.
    def utf8_boundary_offset(line, wrap_width)
      used = 0
      while used < wrap_width
        size = utf8_char_size(line.getbyte(used))
        break if used + size > wrap_width

        used += size
      end
      used
    end

    def utf8_char_size(lead)
      return 1 if lead < 0x80
      return 2 if lead < 0xE0
      return 3 if lead < 0xF0

      4
    end

    def byte_slice(line, start, length)
      line.byteslice(start, length) || ""
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
