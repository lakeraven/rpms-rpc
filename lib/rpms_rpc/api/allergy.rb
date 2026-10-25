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

    # Characters with nothing visible in them, treated as whitespace: zero-width
    # space / non-joiner / joiner, the invisible operators U+2060-2064, the
    # byte-order mark, the soft hyphen, the combining grapheme joiner, the
    # Mongolian vowel separator, tag characters and variation selectors. NOT all
    # of \p{Cf}: U+0600-0605, U+06DD, U+070F and U+110BD are visible.
    INVISIBLE = /[\u200B-\u200D\u2060-\u2064\uFEFF\u00AD\u034F\u180E\u{E0000}-\u{E007F}\uFE00-\uFE0F\u{E0100}-\u{E01EF}]/

    # What separates lines: a bare CR or LF, CRLF, and the Unicode separators.
    LINE_BREAK = /\r\n|\r|\n|\u2028|\u2029|\u0085/

    # ASCII control characters (NUL, RS/US framing, tab ...). A clean row has none.
    CONTROL = /[\u0000-\u001F\u007F]/

    # Lists nested deeper than this (or cyclic) are refused with a typed error
    # rather than recursing without bound.
    MAX_DEPTH = 64

    # The reply nests lists deeper than {MAX_DEPTH}, or is cyclic: not a reply
    # any ORQQAL transport can produce.
    class ReplyTooDeepError < RpmsRpc::Error; end

    # One line of a reply. +text+ is nil for an element with no text at all
    # (nil); +unrecognised+ is true for a line that came from a list inside the
    # list or from a non-text element (ORQQAL cannot emit either); +exact+ is
    # true when the line is the whole of its element (or came from splitting a
    # String reply), i.e. nothing was split off it.
    Line = Struct.new(:text, :unrecognised, :exact)
    private_constant :Line

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
    #   a recognised MARKER   '^' + the marker text and nothing else: the exact
    #                         marker, or one that arrived slightly mangled
    #                         (whitespace, CR, no-break or invisible characters,
    #                         other case, blank extra fields). A marker with any
    #                         non-blank extra field is NOT a marker;
    #   a clean ROW           its first piece is EXACTLY a positive integer (no
    #                         whitespace or invisible character tolerated) and
    #                         piece 2 has allergen text;
    #   BLANK                 a truly EMPTY segment (an empty-string element, or
    #                         what splitting a String leaves between two line
    #                         terminators): not data. Whitespace-only and
    #                         invisible-only content is NOT blank;
    #   UNRECOGNISED          anything else, including an element that is not
    #                         text, a line from a list inside the list, and a
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
    # The principle is: NEVER hide an allergy, NEVER vouch for a reply.
    #
    # Verified absence is strictly byte-exact: only the exact NKA marker as the
    # sole data line is NKA. When the reply is a String, the line terminators
    # that splitting it produces ("marker\r\n") are not part of the marker; when
    # it is an Array, an element that still carries a line terminator is not the
    # byte-exact marker (it is a lone marker: not assessed, never NKA). Nothing
    # strips the RS/US record framing first: no client delivers it inside a line
    # of this reply (XwbClient splits an array reply at CR/LF only; CiaClient
    # splits at RS and drops the lone US node; BmxClient does not carry a stock
    # RPC), so a framing byte glued to the marker, or an element that is only
    # framing beside it, is an unrecognised line, never NKA. A lone marker (any of
    # the three, or a mangled one) is { assessed: false, nka: false, allergies: [] }.
    # Every String (a whole response, or an element of a list) is split into lines
    # first (LF, CR, CRLF, U+2028, U+2029, U+0085), so a marker glued to a row is
    # two lines. A list inside the list is unrecognised, even when empty (it
    # surfaces as its inspect text, e.g. "[]"); so is a non-text element (its
    # inspect text is surfaced). Lists nested deeper than {MAX_DEPTH}, or cyclic,
    # raise {ReplyTooDeepError}.
    #
    # Bytes. CLASSIFICATION reads a scrubbed copy: invalid bytes become U+FFFD
    # (not deleted, so a mangled marker never matches), a string in an encoding
    # that cannot be transcoded is unrecognised. OUTPUT of a clean row is the
    # original bytes and encoding, exactly what main returned: XWB delivers
    # BINARY strings, and a Latin-1 byte in an allergen name is a clean row whose
    # bytes are the boundary's concern (Reply#altered?, rpms-rpc#477). Only a
    # UTF-8-tagged string that is not valid UTF-8, which main raised on, is
    # scrubbed (U+FFFD) before DataMapper sees it. A row needs visible allergen
    # text in piece 2 (not only framing, controls, NUL, invalid bytes or invisible
    # characters) and contains no control character; nothing is stripped to make
    # a row look clean.
    #
    # A reply with any UNRECOGNISED line, or a marker beside any other data
    # (or a marker twice), is the signature of a broker desync, a concatenated
    # or a corrupted reply: its rows may belong to another call (or patient), or
    # the list may be truncated. It is never vouched for:
    #   { assessed: false, nka: false, allergies: [...], conflict: true }
    # ALWAYS assessed: false, never nka. +allergies+ holds the clean rows and,
    # for every unrecognised line with content, a flagged entry
    # { ien: nil, allergen: <line, scrubbed and trimmed, for display>,
    # raw: <the line's original bytes>, unrecognised: true } — never routed
    # through DataMapper's error / no-data filters (which would drop
    # "-3^PENICILLIN" or "^LATEX") and with no guess at which piece is the
    # allergen. A host that renders rows therefore shows the text of such a line;
    # that is intended. Marker lines never become entries; every other line with
    # content does, including whitespace-only, invisible-only, control-only and
    # invalid-byte-only lines (their +raw+ keeps the bytes; +allergen+ may be empty). A FALSE
    # conflict (a real reply that trips this) is loud and safe: assessed: false,
    # never a false "no known allergies". Clean replies carry no :conflict key and
    # no :unrecognised key. This method reports a conflicting reply as NOT
    # assessed; whether a host shows its rows as an incomplete list is the host's
    # job, and a host that must do so MUST read :conflict (one that reads only
    # :nka and :assessed is safe in the absence direction, but may still render
    # the rows as an ordinary list). {for_patient} returns the entries either way.
    def assessment(dfn)
      mapping = DataMapper[:allergy_list]
      response = RpmsRpc.client.call_rpc(mapping.rpc_name, dfn.to_s)
      lines = reply_lines(response).reject { |line| blank?(line) }
      return { assessed: true, nka: true, allergies: [] } if lines.size == 1 && exact_nka?(lines.first)

      kinds = lines.map { |line| kind_of(line) }
      return { assessed: false, nka: false, allergies: [] } if lines.size == 1 && kinds == [ :marker ]
      return conflicting(mapping, lines, kinds) if kinds.any? { |kind| kind != :row }

      allergies = mapping.parse_many(lines.map { |line| parse_ready(line.text) })
      return unparsed(lines) unless allergies.size == lines.size

      { assessed: !allergies.empty?, nka: false, allergies: allergies }
    end
    shape :assessment, resource: "allergies", verb: "GET", path: "/patients/{dfn}/allergies/assessment"

    private

    # The reply is not a clean ORQQAL reply: a marker beside other data, or a
    # line ORQQAL cannot emit (see {assessment}). Not assessed and never nka,
    # whatever the rows are. Clean rows are parsed; every unrecognised line with
    # content is surfaced, flagged, in the order it arrived.
    def conflicting(mapping, lines, kinds)
      allergies = lines.zip(kinds).flat_map do |line, kind|
        case kind
        when :row then mapping.parse_many([ parse_ready(line.text) ])
        when :other then surfaced(line)
        else []
        end
      end
      { assessed: false, nka: false, allergies: allergies, conflict: true }
    end

    # The parser returned fewer rows than it was given: assessed is never
    # claimed on rows that were silently dropped. Surfaced raw, flagged.
    def unparsed(lines)
      { assessed: false, nka: false, allergies: lines.flat_map { |line| surfaced(line) }, conflict: true }
    end

    def kind_of(line)
      return :other if line.unrecognised || line.text.nil? || line.text.encoding.dummy?
      return :marker if marker?(line.text)

      row?(line.text) ? :row : :other
    end

    def exact_nka?(line)
      line.exact && line.text == NKA_SENTINEL
    end

    # An unrecognised line, as a flagged entry; nothing when it has no
    # content. +raw+ keeps the original bytes; +allergen+ is a scrubbed copy, so
    # it can be displayed and serialised (it may be empty for an invisible-only
    # line: rely on +raw+ and +unrecognised+).
    def surfaced(line)
      return [] if line.text.nil? || line.text.empty?

      [ { ien: nil, allergen: displayable(line.text).strip, raw: line.text, unrecognised: true } ]
    end

    # '^' + a marker text and nothing else (blank extra fields allowed). A
    # marker that arrived with whitespace, a carriage return, a no-break space,
    # a zero-width character or a different case is still a marker, so it counts
    # beside data and never becomes an allergy row. Extra NON-blank fields make
    # it something else (an allergen may follow it): unrecognised, surfaced.
    def marker?(text)
      return true if MARKERS.include?(text)

      pieces = squeeze(text).split("^", -1)
      pieces.size >= 2 && pieces[0].empty? &&
        MARKER_TEXTS.include?(pieces[1].gsub(/[[:space:]]+/, " ").strip.downcase) &&
        pieces.drop(2).all? { |piece| squeeze(piece).empty? }
    end

    # A clean row: the first piece is EXACTLY a positive integer (no strip, no
    # squeeze, no invisible tolerance: ORQQAL writes the bare IEN), piece 2 has
    # VISIBLE allergen text, and no control character appears anywhere (RS/US
    # framing and NUL included; nothing is stripped to make a row look clean).
    # Matched on a copy with invalid bytes made visible (U+FFFD), so a stray
    # byte can never be dropped to make an IEN look right.
    def row?(text)
      scrubbed = scrubbed_text(text)
      return false if scrubbed.match?(CONTROL) || c1_codepoint?(text, scrubbed)

      pieces = scrubbed.split("^", -1)
      pieces.size >= 2 && pieces[0].match?(ROW_IEN) && visible?(pieces[1])
    end

    # A real U+0080-U+009F CODEPOINT read from UTF-8 (NEL, CSI ...) is a control
    # sequence, not text. A BYTE 0x80-0x9F in a BINARY string that is not valid
    # UTF-8, or in a Latin-1 / Windows-1252 tagged string, is a byte (printable
    # in Windows-1252), so it is not one. Which charset a live site uses is
    # unproven (rpms-rpc#476).
    def c1_codepoint?(text, scrubbed)
      [ Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII ].include?(text.encoding) && scrubbed.match?(/[\u0080-\u009F]/)
    end

    # Only a truly EMPTY segment (what splitting on line terminators leaves
    # between two terminators, or an empty-string element) is ignorable. Anything
    # with content, including whitespace-only or invisible-only content, is a
    # shape ORQQAL cannot emit: unrecognised, never vouched for.
    def blank?(line)
      line.text == "" && !line.unrecognised
    end

    # Anything a person could see: not whitespace, not an invisible character,
    # not a control character, not an invalid byte.
    def visible?(text)
      !text_of(text).scrub("").gsub(INVISIBLE, "").gsub(/[[:space:]]|\p{Cc}|\uFFFD/, "").empty?
    end

    # The line as text for matching only (the original is never altered):
    # invalid bytes made U+FFFD, invisible characters treated as whitespace (one
    # may stand where the space was) and the ends stripped.
    def squeeze(line)
      scrubbed_text(line).gsub(INVISIBLE, " ").gsub(/\A[[:space:]]+|[[:space:]]+\z/, "")
    end

    def scrubbed_text(line) = text_of(line).scrub("\uFFFD")

    # Read as UTF-8 whatever the client tagged it as (another encoding is
    # transcoded; one with no converter is read as bytes).
    def text_of(line)
      text = line.dup
      case text.encoding
      when Encoding::UTF_8 then text
      when Encoding::BINARY, Encoding::US_ASCII then text.force_encoding(Encoding::UTF_8)
      else
        begin
          text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
        rescue Encoding::ConverterNotFoundError
          text.force_encoding(Encoding::BINARY).force_encoding(Encoding::UTF_8)
        end
      end
    end

    # Text a host can display and serialise.
    def displayable(line)
      scrubbed_text(line)
    end

    # What DataMapper is given for a clean row: the ORIGINAL line, so the output
    # bytes and encoding are exactly what main returned. Only a UTF-8-tagged
    # string that is not valid UTF-8 (its regexes raise on it) is scrubbed.
    def parse_ready(line)
      return line unless line.encoding == Encoding::UTF_8 && !line.valid_encoding?

      line.scrub("\uFFFD")
    end

    # Text and lists of lines are replies. Every String (a whole response or an
    # element of a list) is split into lines first, so a marker glued to a row
    # by a bare LF, CR or a Unicode separator is two lines. A list inside the
    # list is unrecognised (even an empty one, which surfaces as its inspect
    # text), and so is a non-text element.
    def reply_lines(response)
      case response
      when nil then []
      when String then split_lines(response).map { |text| Line.new(text, false, true) }
      when Array then array_lines(response, 1, false)
      else [ Line.new(response.inspect, true, false) ]
      end
    end

    def array_lines(array, level, nested)
      raise ReplyTooDeepError, "allergy reply nests lists deeper than #{MAX_DEPTH} (or is cyclic)" if level > MAX_DEPTH

      array.flat_map do |item|
        case item
        when Array
          inner = array_lines(item, level + 1, true)
          inner.empty? ? [ Line.new(item.inspect, true, false) ] : inner
        when String
          pieces = split_lines(item)
          exact = !nested && pieces == [ item ]
          pieces.map { |text| Line.new(text, nested, exact) }
        when nil then [ Line.new(nil, true, false) ]
        else [ Line.new(item.inspect, true, false) ]
        end
      end
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
  end
end
