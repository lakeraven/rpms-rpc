# frozen_string_literal: true

require_relative "../shape"

module RpmsRpc
  # Symbolic API for patient allergies (ORQQAL LIST). The RPC is
  # three-state (LIST^ORQQAL — ORQQAL.m:7): not-assessed
  # ("^No Allergy Assessment"), assessed with no known allergies
  # ("^No Known Allergies"), or assessed with allergy records. Use
  # {assessment} when the caller must distinguish NKA from unassessed
  # (FHIR AllergyIntolerance must); {for_patient} keeps the plain
  # record-array shape.
  module Allergy
    extend self
    extend Shape::Declarable

    NOT_ASSESSED_SENTINEL       = "^No Allergy Assessment" # ORQQAL.m:12
    NKA_SENTINEL                = "^No Known Allergies"    # ORQQAL.m:13
    NO_ALLERGIES_FOUND_SENTINEL = "^No allergies found."   # ORQQAL.m:15, written only when no row was
    MARKERS = [ NOT_ASSESSED_SENTINEL, NKA_SENTINEL, NO_ALLERGIES_FOUND_SENTINEL ].freeze

    # The text of each marker, for recognising one that arrived slightly mangled.
    MARKER_TEXTS = MARKERS.map { |marker| marker.delete_prefix("^").downcase }.freeze

    # Every real row begins with the allergy IEN, a positive integer:
    # ORQQAL.m:13 writes $P(GMRARXN(J),"^",3) = GMRAIEN first, and GMRAOR1.m
    # EN1 loops "Q:GMRAIEN<1". Anything else is not a row ORQQAL can emit.
    ROW_IEN = /\A[1-9]\d*\z/

    # Characters with nothing visible in them, treated as whitespace: format
    # characters (zero-width space/joiners, word joiner, soft hyphen, byte-order
    # mark ...) plus the combining grapheme joiner and the Mongolian vowel
    # separator.
    INVISIBLE = /[\p{Cf}\u034F\u180E]/

    # What separates lines: a bare CR or LF, CRLF, and the Unicode separators.
    LINE_BREAK = /\r\n|\r|\n|\u2028|\u2029|\u0085/

    # An element of a reply that is not text (a Hash, a number, nil, a nested
    # list). It is unrecognised and carries no allergen text.
    UNREADABLE = Object.new.freeze

    # Allergy records only. An NKA or unassessed patient yields [] —
    # callers that need to tell those apart must use {assessment}. The rows
    # of a conflicting reply (a marker beside other data) are returned too,
    # because hiding a possible allergy is unsafe; this method cannot tell a
    # verified list from a conflicting one, so a host that must make that
    # distinction MUST use {assessment} and read :assessed and :conflict.
    def for_patient(dfn)
      assessment(dfn)[:allergies]
    end
    shape :for_patient, resource: "allergies", verb: "GET", path: "/patients/{dfn}/allergies"

    # Three-state assessment result:
    #   { assessed: true,  nka: false, allergies: [...] } records on file
    #   { assessed: true,  nka: true,  allergies: [] }    assessed, NKA
    #   { assessed: false, nka: false, allergies: [] }    no assessment
    # An empty/indeterminate response (including the "^No allergies found."
    # fallback ORQQAL.m:15 emits when the classifier produced no rows) is
    # reported as not-assessed — the clinically safe reading, since claiming
    # "assessed" without evidence would suppress a real assessment prompt.
    #
    # Every line of a reply is one of four things:
    #   a recognised MARKER   the exact marker, or one that arrived slightly
    #                         mangled (whitespace, CR, no-break or invisible
    #                         characters, other case, an extra ^ field);
    #   a valid ROW           its first piece is a positive integer;
    #   BLANK                 nothing visible in it: not data;
    #   UNRECOGNISED          anything else, including an element that is not
    #                         text (nil, a Hash, a number, a nested list) and a
    #                         line whose bytes are not valid text.
    # Why this is evidence-based and not another list of characters:
    # LIST^ORQQAL (ORQQAL.m:7-16) sets GMRARXN to "", 0 or 1 — mutually
    # exclusive branches — and writes one of exactly THREE markers: "^No
    # Allergy Assessment" and "^No Known Allergies" to ORAY(1) only in the two
    # branches that write no rows, and "^No allergies found." (line 15) only when
    # no row was written at all. Rows come only from the third branch, and every
    # row begins with the allergy IEN (line 13 writes $P(GMRARXN(J),"^",3) =
    # GMRAIEN first; GMRAOR1.m EN1 loops "Q:GMRAIEN<1"), a positive integer. So a
    # real reply is ONE marker line OR rows, never both, and every row's first
    # piece is numeric. Anything ORQQAL cannot emit is, by definition, not a
    # clean reply, and an unknown lookalike can only make the answer LOUDER.
    #
    # Verified absence is strictly byte-exact: only the exact NKA marker as the
    # sole data line is NKA. A lone marker (any of the three, or a mangled one)
    # is { assessed: false, nka: false, allergies: [] }. Every String (a whole
    # response, or an element of a list) is split into lines first (LF, CR, CRLF,
    # U+2028, U+2029, U+0085), so a marker glued to a row is two lines.
    #
    # A reply with any UNRECOGNISED line, or a marker beside any other data
    # (or a marker twice), is the signature of a broker desync, a concatenated
    # or a corrupted reply: its rows may belong to another call (or patient), or
    # the list may be truncated. It is never vouched for:
    #   { assessed: false, nka: false, allergies: [...], conflict: true }
    # ALWAYS assessed: false, never nka. Valid rows, and any unrecognised line
    # that carries allergen text, are still returned — hiding a possible
    # allergy is the other unsafe direction — flagged, not dropped; an
    # unrecognised line with no allergen text makes no row, and marker lines
    # never become rows. With no rows it is the same shape with allergies: [].
    # A FALSE conflict (a real reply that trips this) is loud and safe:
    # assessed: false, never a false "no known allergies". Clean replies carry no
    # :conflict key. This method reports a conflicting reply as NOT assessed;
    # whether a host shows its rows as an incomplete list is the host's job, and
    # a host that must do so MUST read :conflict (one that reads only :nka and
    # :assessed is safe in the absence direction, but may still render the rows
    # as an ordinary list). {for_patient} returns the rows either way.
    def assessment(dfn)
      mapping = DataMapper[:allergy_list]
      response = RpmsRpc.client.call_rpc(mapping.rpc_name, dfn.to_s)
      data = reply_lines(response).reject { |line| blank?(line) }
      return { assessed: true, nka: true, allergies: [] } if data == [ NKA_SENTINEL ]

      markers, others = data.partition { |line| marker?(line) }
      return { assessed: false, nka: false, allergies: [] } if data.size == 1 && !markers.empty?
      return conflicting(mapping, others) if !markers.empty? || others.any? { |line| !row?(line) }

      allergies = mapping.parse_many(others.map { |line| parse_ready(line) })
      { assessed: !allergies.empty?, nka: false, allergies: allergies }
    end
    shape :assessment, resource: "allergies", verb: "GET", path: "/patients/{dfn}/allergies/assessment"

    private

    # The reply is not a clean ORQQAL reply: a marker beside other data, or a
    # line ORQQAL cannot emit (see {assessment}). Not assessed and never nka,
    # whatever the rows are. Valid rows, and any unrecognised line that carries
    # allergen text, are returned so that a possible allergy is flagged and
    # never hidden; an unrecognised line with no allergen text makes no row.
    def conflicting(mapping, others)
      kept = others.select { |line| row?(line) || allergen_text?(line) }
      { assessed: false, nka: false, allergies: mapping.parse_many(kept.map { |line| parse_ready(line) }), conflict: true }
    end

    # Verified absence is strictly byte-exact (only the exact NKA marker as the
    # sole data line); this is the wider test used for conflict detection. A
    # marker that arrived with whitespace, a carriage return, a no-break space,
    # a zero-width character, a different case or an extra field is still a
    # marker, so it counts beside data and never becomes an allergy row.
    def marker?(line)
      return false unless line.is_a?(String)
      return true if MARKERS.include?(line)

      pieces = squeeze(line).split("^", -1)
      pieces.size >= 2 && pieces[0].empty? && MARKER_TEXTS.include?(pieces[1].gsub(/[[:space:]]+/, " ").strip.downcase)
    end

    # A valid row: its first piece is a positive integer (the allergy IEN).
    def row?(line)
      line.is_a?(String) && squeeze(line).split("^", -1).first.to_s.strip.match?(ROW_IEN)
    end

    # The second piece, where the allergen text sits, is not blank.
    def allergen_text?(line)
      line.is_a?(String) && !squeeze(line).split("^", -1)[1].to_s.strip.empty?
    end

    # A line with nothing visible in it is not data and never becomes a row. A
    # line whose bytes are not valid text is not "nothing": it is unrecognised.
    def blank?(line)
      line.is_a?(String) && squeeze(line).empty? && text_of(line).valid_encoding?
    end

    # The line as text for matching only (the original is never altered): read
    # as UTF-8 whatever the client tagged it as (another encoding is
    # transcoded), invalid bytes dropped, invisible characters treated as
    # whitespace (one may stand where the space was) and the ends stripped.
    def squeeze(line)
      text_of(line).scrub("").gsub(INVISIBLE, " ").gsub(/\A[[:space:]]+|[[:space:]]+\z/, "")
    end

    def text_of(line)
      text = line.dup
      case text.encoding
      when Encoding::UTF_8 then text
      when Encoding::BINARY, Encoding::US_ASCII then text.force_encoding(Encoding::UTF_8)
      else text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
      end
    end

    # A line DataMapper can parse: text that is not valid UTF-8 would raise in
    # its regexes, so it is read as text first (invalid bytes become U+FFFD).
    def parse_ready(line)
      return line if line.ascii_only? || (line.encoding == Encoding::UTF_8 && line.valid_encoding?)

      text_of(line).scrub("\uFFFD")
    end

    # Text and lists of lines are replies. Every String (a whole response or an
    # element of a list) is split into lines first, so a marker glued to a row
    # by a bare LF, CR or a Unicode separator is two lines. Anything that is not
    # text (nil, a Hash, a number, a nested list) is one unreadable element:
    # unrecognised, never a row built from its string form.
    def reply_lines(response)
      items = case response
      when nil then []
      when String then [ response ]
      when Array then response
      else [ UNREADABLE ]
      end
      items.flat_map { |item| item.is_a?(String) ? split_lines(item).map { |line| strip_separators(line) } : [ UNREADABLE ] }
    end

    def split_lines(text)
      utf8 = [ Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII ].include?(text.encoding) ? text.dup.force_encoding(Encoding::UTF_8) : nil
      lines = if utf8&.valid_encoding?
        utf8.split(LINE_BREAK)
      else
        text.dup.force_encoding(Encoding::BINARY).split(/\r\n|\r|\n/n)
      end
      lines.map { |line| line.force_encoding(text.encoding) }
    end

    # Trailing recordset framing (RS/US), as DataMapper.strip_recordset_separators
    # does, but on the bytes: a regex on text that is not valid UTF-8 raises.
    def strip_separators(line)
      bytes = line.b
      stripped = bytes.sub(/[\x1E\x1F]+\z/n, "")
      stripped.bytesize == bytes.bytesize ? line : stripped.force_encoding(line.encoding)
    end
  end
end
