# frozen_string_literal: true

require_relative "../shape"
require_relative "../reply"

module RpmsRpc
  # Symbolic API for patient allergies. The read is ORQQAL LIST,
  # three-state (LIST^ORQQAL — ORQQAL.m:7): not-assessed
  # ("^No Allergy Assessment"), assessed with no known allergies
  # ("^No Known Allergies"), or assessed with allergy records. Use
  # {assessment} when the caller must distinguish NKA from unassessed
  # (FHIR AllergyIntolerance must); {for_patient} keeps the plain
  # record-array shape.
  #
  # The write is ORWDAL32 SAVE ALLERGY, EDITSAVE^ORWDAL32
  # (ORWDAL32.m:119): ORALIEN "" adds, ORDFN is the patient, and
  # OREDITED is merged into ^TMP("GMRA",$J) (ORWDAL32.m:124).
  # GMRANKA="YES" is NKA^GMRAGUI1 (ORWDAL32.m:127); otherwise
  # UPDATE^GMRAGUI1 (ORWDAL32.m:128). The new #120.8 IEN stays inside
  # UPDATE and is not returned — re-read the list to find the entry.
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
    # For UTF-8, BINARY and US-ASCII text the UTF-8 BYTE sequences for U+2028,
    # U+2029 and U+0085 split too, matched on bytes whether or not the rest of
    # the line is valid UTF-8; in a single-byte encoding a lone 0x85 is a
    # character, not a line break.
    UTF8_LINE_BREAK = /\r\n|\r|\n|\xE2\x80\xA8|\xE2\x80\xA9|\xC2\x85/n
    ASCII_LINE_BREAK = /\r\n|\r|\n/n

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
    # String reply), i.e. nothing was split off it; +altered+ is true when the
    # client replaced a byte of the element the line came from to make it valid
    # UTF-8 (RpmsRpc::Reply#altered_lines, rpms-rpc#463).
    Line = Struct.new(:text, :unrecognised, :exact, :altered)
    private_constant :Line

    # EDITSAVE^ORWDAL32 (ORWDAL32.m:119). Return type is a single value.
    SAVE_ALLERGY_RPC = "ORWDAL32 SAVE ALLERGY"

    # UPDATE^GMRAGUI1 reads these named subscripts (GMRAGUI1.m:104).
    # GMRAGNT is "agent^variable pointer" (GMRAGUI1.m:89, :106).
    REQUIRED_FIELDS = %i[
      agent agent_pointer type nature originator originated_at observed_or_historical
    ].freeze

    # An empty string on these is an invalid value, not a missing field.
    # nil is still absence ({absent_required}).
    FORMAT_FIELDS = %i[agent_pointer originated_at type nature].freeze

    # GMRAOBHX is exactly "o" (observed) or "h" (historical) (GMRAGUI1.m:135).
    OBHX = %w[o h].freeze

    # GMRAGNT piece 2 is "IEN;GLOBAL(FILE," (GMRAGUI1.m:106) or a global root
    # with no file number, "IEN;GLOBAL(" (ORWDAL32.m:30, ^PSDRUG( is file 50).
    # A file number still needs its trailing comma: "45;PSDRUG(1", a lowercase
    # root, and "0;..." are not pointers.
    AGENT_POINTER = /\A[1-9]\d*;[A-Z][A-Z0-9]*\((\d+(\.\d+)?,)?\z/

    # GMRAORDT (GMRAGUI1.m:104) and GMRARDT (GMRAGUI1.m:137 stock / :135 FOIA).
    FILEMAN_DATE = /\A\d{7}(\.\d{1,6})?\z/

    # GMRATYPE (field 3.1) is one or more distinct letters from D, F, O
    # (ORWDAL32.m:81). "DD" repeats one; "ZZ" is outside the set.
    TYPE = /\A[DFO]+\z/

    # GMRANATR (field 17) is A, P or U (ORWDAL32.m:77).
    NATURE = %w[A P U].freeze

    # GMRASEVR is "1" mild, "2" moderate or "3" severe (ORWDAL32.m:88-89).
    SEVERITY = %w[1 2 3].freeze

    # "-1^Patient already has a <agent> reaction entered.  No duplicates allowed."
    # (GMRAGUI1.m:89). Two spaces before "No".
    DUPLICATE_REPLY = %r{\A-1\^Patient already has a .+ reaction entered\.  No duplicates allowed\.\z}

    # MESS^GMRAGUI1 joins the two sentences with two spaces
    # (GMRAGUI1.m:160 stock / :157 FOIA).
    LOCK_REPLY = "-1^Another user is editing this patient's allergy information.  " \
                 "Please refresh/review the patient's information before proceeding."

    # NKA^GMRAGUI1 (GMRAGUI1.m:75).
    ACTIVE_ALLERGIES_REPLY = "-1^Patient has active allergies - can't mark as NKA"

    # NKA^GMRAGUI1 file-header and record locks (GMRAGUI1.m:76, :80).
    ASSESSMENT_UPDATE_REPLY = "-1^Unable to update assessment - try again."

    # "0" or "0^<note IEN>" (GMRAGUI1.m:149 stock / :147 FOIA).
    SUCCESS_REPLY = /\A0(?:\^(\d+))?\z/

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
    # a row look clean. Known limit, shared with main: on the CIA line path a
    # control character inside a line is replaced by a space before this runs,
    # so it joins a row to a marker or folds a second allergy into the first
    # row's fields as one altered row (see the README); ORQQAL writes one row or
    # marker per node, so only a control byte stored in a GMRA field can do it.
    #
    # A reply with any UNRECOGNISED line, or a marker beside any other data
    # (or a marker twice), is the signature of a broker desync, a concatenated
    # or a corrupted reply: its rows may belong to another call (or patient), or
    # the list may be truncated. It is never vouched for:
    #   { assessed: false, nka: false, allergies: [...], conflict: true }
    # ALWAYS assessed: false, never nka. +allergies+ holds the clean rows and,
    # for every unrecognised line with content, a flagged entry
    # { ien: nil, allergen: <line, scrubbed and trimmed, for display>,
    # raw: <the line as the reply holds it>, unrecognised: true } — never routed
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

      allergies = rows_of(mapping, lines)
      return unparsed(lines) unless allergies.size == lines.size

      { assessed: !allergies.empty?, nka: false, allergies: allergies }
    end
    shape :assessment, resource: "allergies", verb: "GET", path: "/patients/{dfn}/allergies/assessment"

    # Add an allergy. ORALIEN "" is new: UPDATE sets NEW='$G(GMRAIEN)
    # (GMRAGUI1.m:88) and EDITSAVE passes that ORALIEN through
    # (ORWDAL32.m:128). OREDITED carries GMRAGNT, GMRATYPE, GMRANATR,
    # GMRAORIG, GMRAORDT, GMRAOBHX (GMRAGUI1.m:104), optional
    # GMRASYMP(n) (GMRAGUI1.m:120 stock / :118 FOIA) and GMRACMTS(n)
    # (GMRAGUI1.m:118 stock / :116 FOIA) as two-level subscripts, and
    # optional GMRARDT / GMRASEVR (GMRAGUI1.m:137 stock / :135 FOIA).
    # nil or "" reaction_date and severity are absent: not validated and
    # not put in OREDITED (GMRAGUI1.m:137 $G of a missing subscript).
    #
    #   save(dfn, allergy) => { success: true, note_ien: Integer or nil }
    #                     or { success: false, error:, message: }
    # A value the wire cannot frame is
    # { success: false, error: :frame_too_long, message: } (#472).
    #
    # Refused before the RPC: a String that fails {text_encoding_ok?}
    # (valid_encoding? is false, or the string is ASCII-8BIT / BINARY
    # with a high byte), before any regexp; a "^" or a control in any
    # $P-split filed value ($P on U drops the rest — GMRAGUI1.m:105),
    # including optional GMRARDT and GMRASEVR when present (GMRAGUI1.m:137
    # stock / :135 FOIA); an agent that is not visible text ({visible?});
    # GMRAOBHX other than "o"/"h" (GMRAGUI1.m:135); a GMRAORIG that is not
    # a positive DUZ (GMRAGUI1.m:104); symptoms that are not an Array of
    # Hashes (GMRAGUI1.m:122) whose :ien is a positive canonical integer
    # or exactly "FT" (GMRAGUI1.m:126), whose :text is visible text
    # ({visible?}; piece 2 is a GMRAROT subscript at GMRAGUI1.m:132, and
    # a blank, whitespace-only or invisible-only piece is a null
    # subscript after the entry is filed) and whose :date, when present
    # and non-blank, is a FileMan date
    # (GMRAGUI1.m:130); or comments that are not an Array of visible
    # Strings (GMRAGUI1.m:118). A caret in a comment line is allowed: the
    # line is filed whole through ^DIWP (ORWDAL32.m:137-138 ->
    # GMRAGUI1.m:118 -> GMRAGUI1.m:59-60). Control characters in a comment
    # stay refused. GMRAGNT's pointer is "IEN;GLOBAL(FILE,"
    # (GMRAGUI1.m:106) or a global root with no file number,
    # "IEN;GLOBAL(" (ORWDAL32.m:30, ^PSDRUG( is file 50). GMRAORDT and a
    # present GMRARDT are FileMan dates, a present GMRASEVR is "1", "2"
    # or "3", or the Integer 1, 2 or 3 sent as that String
    # (ORWDAL32.m:88-89), GMRATYPE is one or more distinct letters from
    # D, F and O (ORWDAL32.m:81), and GMRANATR is A, P or U
    # (ORWDAL32.m:77).
    def save(dfn, allergy)
      patient = canonical_dfn(dfn)
      return invalid_dfn unless patient

      missing = absent_required(allergy)
      return missing_allergy(missing) unless missing.empty?

      refusal = refused_allergy(allergy)
      return refusal if refusal

      dispatch(patient, edited_list(allergy))
    end
    shape :save, resource: "allergies", verb: "POST", path: "/patients/{dfn}/allergies"

    # Record no known allergies. OREDITED("GMRANKA")="YES" selects
    # NKA^GMRAGUI1 (ORWDAL32.m:127, GMRAGUI1.m:68); ORALIEN is "".
    # Already-NKA leaves ORY at the 0 EDITSAVE set (ORWDAL32.m:125,
    # GMRAGUI1.m:74).
    def no_known_allergies(dfn)
      patient = canonical_dfn(dfn)
      return invalid_dfn unless patient

      dispatch(patient, { "GMRANKA" => "YES" })
    end
    shape :no_known_allergies, resource: "allergies", verb: "POST", path: "/patients/{dfn}/allergies/no-known"

    private

    # The reply is not a clean ORQQAL reply: a marker beside other data, or a
    # line ORQQAL cannot emit (see {assessment}). Not assessed and never nka,
    # whatever the rows are. Clean rows are parsed; every unrecognised line with
    # content is surfaced, flagged, in the order it arrived.
    def conflicting(mapping, lines, kinds)
      allergies = lines.zip(kinds).flat_map do |line, kind|
        case kind
        when :row then rows_of(mapping, [ line ])
        when :other then surfaced(line)
        else []
        end
      end
      { assessed: false, nka: false, allergies: allergies, conflict: true }
    end

    # The rows of clean lines, each saying whether any of its text was altered
    # to become valid UTF-8 (`altered:`, rpms-rpc#463): two allergens that
    # differ only in a byte the gem replaced read identically, and a host must
    # be able to refuse them. A row's flag is its own line's, never its
    # neighbour's. Altering is NOT a conflict: the line is still a clean row.
    # (A clean row always carries the key; a surfaced unrecognised entry
    # carries `altered: true` only when altered, see {surfaced}.)
    def rows_of(mapping, lines)
      lines.flat_map do |line|
        ready = parse_ready(line.text)
        scrubbed_here = ready.encoding == Encoding::UTF_8 && ready != line.text
        flagged = line.altered || scrubbed_here
        mapping.parse_many_flagged([ ready ], flagged ? [ 0 ] : [])
      end
    end

    # The parser returned fewer rows than it was given: assessed is never
    # claimed on rows that were silently dropped. Surfaced raw, flagged.
    def unparsed(lines)
      { assessed: false, nka: false, allergies: lines.flat_map { |line| surfaced(line) }, conflict: true }
    end

    def kind_of(line)
      return :other if line.unrecognised || line.text.nil? || !byte_view?(line.text.encoding)
      return :marker if marker?(line.text) && !line.altered

      row?(line.text) ? :row : :other
    end

    def exact_nka?(line)
      line.exact && !line.altered && line.text == NKA_SENTINEL
    end

    # An unrecognised line, as a flagged entry; nothing when it has no
    # content. +raw+ is the line as the reply holds it: the original bytes for a
    # plain reply, but the text AFTER alteration for a Reply or Text that altered
    # it (invalid bytes become U+FFFD, a control character becomes a space), so
    # for an altered marker +raw+ can equal the marker text. Never compare +raw+
    # to a sentinel: read +unrecognised+, +altered+ and the reply's +conflict+.
    # +allergen+ is a scrubbed copy, so it can be displayed and serialised (it
    # may be empty for an invisible-only line: rely on +raw+ and +unrecognised+).
    def surfaced(line)
      return [] if line.text.nil? || line.text.empty?

      entry = { ien: nil, allergen: displayable(line.text).strip, raw: line.text, unrecognised: true }
      entry[:altered] = true if line.altered
      [ entry ]
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
      pieces.size >= 2 && pieces[0].match?(ROW_IEN) && visible?(pieces[1]) &&
        pieces.drop(4).all? { |piece| squeeze(piece).empty? }
    end

    # UTF-8, BINARY and US-ASCII are read as their bytes, and so are the
    # single-byte ISO-8859-x / Windows-125x tags (never transcoded, so no byte
    # is deleted or invented). Any other tag (UTF-16/32, UTF-7, Shift_JIS,
    # EUC-JP ...) is not a view this method can read as ORQQAL text: unrecognised.
    def byte_view?(encoding)
      [ Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII ].include?(encoding) || encoding.name.match?(/\A(?:ISO-8859-\d+|Windows-125\d)\z/)
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
      line.text == ""
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

    # The bytes of the line, read as UTF-8 (whatever the client tagged them
    # as): nothing is transcoded and no byte is deleted.
    def text_of(line)
      line.dup.force_encoding(Encoding::UTF_8)
    end

    # Text a host can display and serialise.
    def displayable(line)
      scrubbed_text(line)
    end

    # What DataMapper is given for a clean row: the ORIGINAL line, so the output
    # bytes and encoding are what main returned. Only a UTF-8-tagged string that
    # is not valid UTF-8, or a US-ASCII-tagged one with a high byte (their
    # regexes raise on it), is changed: scrubbed to U+FFFD, or read as BINARY.
    def parse_ready(line)
      case line.encoding
      when Encoding::UTF_8 then line.valid_encoding? ? line : line.scrub("\uFFFD")
      when Encoding::US_ASCII then line.valid_encoding? ? line : line.b
      else line
      end
    end

    # Text and lists of lines are replies. Every String (a whole response or an
    # element of a list) is split into lines first, so a marker glued to a row
    # by a bare LF, CR or a Unicode separator is two lines. A list inside the
    # list is unrecognised (even an empty one, which surfaces as its inspect
    # text), and so is a non-text element.
    def reply_lines(response)
      case response
      when nil then []
      when String then string_lines(response)
      when Array then array_lines(response, 1, false, response.is_a?(Reply) ? response.altered_lines : [])
      else [ Line.new(response.inspect, true, false, false) ]
      end
    end

    # +flags+: at the top level, the indexes of the elements the client altered
    # (a Reply's altered_lines); every line split off, or nested inside, an
    # altered element is altered. Below the top level, +flags+ is true or false.
    def array_lines(array, level, nested, flags)
      raise ReplyTooDeepError, "allergy reply nests lists deeper than #{MAX_DEPTH} (or is cyclic)" if level > MAX_DEPTH

      array.each_with_index.flat_map do |item, index|
        altered = level == 1 ? flags.include?(index) : flags
        case item
        when Array
          inner = array_lines(item, level + 1, true, altered)
          inner.empty? ? [ Line.new(item.inspect, true, false, altered) ] : inner
        when String
          pieces = split_lines(item)
          exact = !nested && pieces == [ item ]
          marked = Reply.altered_indexes(item, pieces)
          pieces.each_with_index.map { |text, i| Line.new(text, nested, exact, altered || marked.include?(i)) }
        when nil then [ Line.new(nil, true, false, altered) ]
        else [ Line.new(item.inspect, true, false, altered) ]
        end
      end
    end

    # A reply that arrives as one String. When it is a Reply::Text that altered
    # something, the altered lines are the ones Reply.altered_indexes names
    # (the same evidence Reply.lines_with_altered uses).
    def string_lines(response)
      pieces = split_lines(response)
      marked = Reply.altered_indexes(response, pieces)
      pieces.each_with_index.map { |text, index| Line.new(text, false, true, marked.include?(index)) }
    end

    # Split on bytes, so a line that is not valid UTF-8 still splits.
    def split_lines(text)
      breaks = [ Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII ].include?(text.encoding) ? UTF8_LINE_BREAK : ASCII_LINE_BREAK
      text.b.split(breaks).map { |line| line.force_encoding(text.encoding) }
    end

    # A DFN is a positive canonical integer: a positive Integer, or a
    # string of digits with no leading zero and no trailing junk
    # ("12abc" is not 12).
    def canonical_dfn(value)
      case value
      when Integer then value.positive? ? value.to_s : nil
      when String
        return nil unless text_encoding_ok?(value)

        value.match?(/\A[1-9]\d*\z/) ? value : nil
      end
    end

    def absent_required(allergy)
      return REQUIRED_FIELDS unless allergy.is_a?(Hash)

      REQUIRED_FIELDS.select { |field| absent_value?(field, allergy[field]) }
    end

    # nil is absence. A blank string on a {FORMAT_FIELDS} field is refused
    # by the format checks in {refused_allergy} (an empty GMRATYPE is not
    # "one or more" letters), so it is not reported as missing. A String
    # agent is present even when blank or invisible: that is an invalid
    # value ({agent_visible?}), not a missing field. nil agent is still
    # absence.
    def absent_value?(field, value)
      return false if field == :agent && value.is_a?(String)
      return false if value.is_a?(String) && blank_field?(value) && FORMAT_FIELDS.include?(field)

      blank_field?(value)
    end

    def blank_field?(value)
      return true if value.nil?

      text = value.to_s
      # strip walks characters and raises on bytes that are not valid text.
      return false unless text_encoding_ok?(text)

      text.strip.empty?
    end

    def invalid_dfn
      { success: false, error: :invalid_dfn, message: "a positive DFN is required" }
    end

    def missing_allergy(fields)
      { success: false, error: :missing_fields, message: "missing #{fields.join(", ")}" }
    end

    def invalid_value(field)
      { success: false, error: :invalid_value, message: "invalid #{field}" }
    end

    # See {save}. A blank GMRASYMP first piece is not stored (GMRAGUI1.m:122).
    # :ien is a positive canonical integer or exactly "FT" (GMRAGUI1.m:126);
    # :text is visible text ({visible?}; GMRAGUI1.m:132); :date, when
    # present and non-blank, is a FileMan date (GMRAGUI1.m:130).
    # Shape checks stay ahead of {unsafe_field}, and that pass stays
    # ahead of the format checks, so a value that fails more than one
    # is named by the earlier one. A caret or bad encoding on the agent
    # is named before an invisible agent. {text_encoding_ok?} runs
    # before any regexp. Present reaction_date and severity (not nil or
    # "") are in that caret check, so a caret there is named before a
    # type, nature or other format fault.
    def refused_allergy(allergy)
      return invalid_value(:symptoms) unless symptoms_shape?(allergy[:symptoms])
      return invalid_value(:comments) unless comments_ok?(allergy[:comments])

      field = unsafe_field(allergy)
      return invalid_value(field) if field

      return invalid_value(:symptoms) unless symptoms_ok?(allergy[:symptoms])
      return invalid_value(:observed_or_historical) unless OBHX.include?(allergy[:observed_or_historical])
      return invalid_value(:originator) unless canonical_dfn(allergy[:originator])
      return invalid_value(:agent_pointer) unless agent_pointer_ok?(allergy[:agent_pointer])
      return invalid_value(:originated_at) unless fileman_date?(allergy[:originated_at])
      return invalid_value(:type) unless type_ok?(allergy[:type])
      return invalid_value(:nature) unless NATURE.include?(allergy[:nature])
      return invalid_value(:reaction_date) unless reaction_date_ok?(allergy[:reaction_date])
      return invalid_value(:severity) unless severity_ok?(allergy[:severity])

      nil
    end

    # Array of Hashes, or absent. :ien / :text / :date format is
    # {symptom_ok?}, and it runs after the caret check.
    def symptoms_shape?(symptoms)
      return true if symptoms.nil?
      return false unless symptoms.is_a?(Array)

      symptoms.all? { |symptom| symptom.is_a?(Hash) }
    end

    def symptoms_ok?(symptoms)
      return true if symptoms.nil?
      return false unless symptoms.is_a?(Array)

      symptoms.all? { |symptom| symptom_ok?(symptom) }
    end

    # :ien is a positive canonical integer or exactly "FT" (GMRAGUI1.m:126).
    # :text is visible text ({visible?}). Piece 2 is the GMRAROT subscript
    # (GMRAGUI1.m:132) after the entry is filed, so a blank,
    # whitespace-only or invisible-only piece is a null subscript.
    # :date, when present and non-blank, is a FileMan date
    # (GMRAGUI1.m:130).
    def symptom_ok?(symptom)
      return false unless symptom.is_a?(Hash)
      return false unless symptom[:ien] == "FT" || canonical_dfn(symptom[:ien])
      return false unless symptom[:text].is_a?(String) && text_encoding_ok?(symptom[:text]) && visible?(symptom[:text])

      omitted?(symptom[:date]) || fileman_date?(symptom[:date])
    end

    def comments_ok?(comments)
      return true if comments.nil?
      return false unless comments.is_a?(Array)

      comments.all? { |line| line.is_a?(String) }
    end

    def unsafe_field(allergy)
      bad = REQUIRED_FIELDS.find { |field| unsafe_text?(allergy[field]) }
      return bad if bad
      return :agent unless agent_visible?(allergy[:agent])

      bad = unsafe_symptom(allergy[:symptoms])
      return bad if bad

      bad = comment_fault(allergy[:comments])
      return bad if bad

      # nil and "" are absent, not a caret (GMRAGUI1.m:137 $G).
      %i[reaction_date severity].find { |field| !omitted?(allergy[field]) && unsafe_text?(allergy[field]) }
    end

    def unsafe_symptom(symptoms)
      Array(symptoms).filter_map { |symptom| symptom.keys.find { |name| unsafe_text?(symptom[name]) } }.first
    end

    # GMRAGNT piece 1 is the allergen name. Blank, whitespace-only and
    # invisible-only text is not a name a clinician can read ({visible?}).
    # Encoding is checked before that regexp. nil is absence
    # ({absent_value?}), not this failure.
    def agent_visible?(agent)
      return false if agent.nil?

      text = agent.is_a?(String) ? agent : agent.to_s
      text_encoding_ok?(text) && visible?(text)
    end

    # Carets are allowed in comment lines: they are filed whole through
    # ^DIWP (ORWDAL32.m:137-138 -> GMRAGUI1.m:118 -> GMRAGUI1.m:59-60).
    # Control characters stay refused. Carets stay refused in the agent
    # and every other $P-split field (GMRAGNT uses $P(...,U) at
    # GMRAGUI1.m:105-106). Each line must also be visible text
    # ({visible?}). Encoding is checked before either regexp.
    def comment_fault(comments)
      return nil unless comments.is_a?(Array)

      comments.each do |line|
        return :comments unless line.is_a?(String)
        return :comment unless text_encoding_ok?(line)
        return :comment if line.match?(CONTROL)
        return :comments unless visible?(line)
      end
      nil
    end

    # "^" splits a $P piece (GMRAGUI1.m:105); ASCII controls are frame
    # bytes. Invalid text is refused first ({text_encoding_ok?}): match?
    # raises ArgumentError on invalid UTF-8 and Encoding::CompatibilityError
    # on ASCII-8BIT with a high byte against a UTF-8 regexp. Comment lines
    # are not $P-split; {comment_fault} does not use this caret check.
    def unsafe_text?(value)
      text = value.to_s
      return true unless text_encoding_ok?(text)

      text.include?("^") || text.match?(CONTROL)
    end

    # A String a save-path regexp may read. valid_encoding? is checked
    # first. ASCII-8BIT (alias BINARY) accepts every byte, so a high byte
    # is refused on its own — otherwise a UTF-8 regexp raises
    # Encoding::CompatibilityError, and a US-ASCII regexp can miss it.
    # Every free-text check in {save} and {no_known_allergies} goes through
    # this before match?, strip, or {visible?}.
    def text_encoding_ok?(text)
      return false unless text.is_a?(String)
      return false unless text.valid_encoding?

      text.encoding != Encoding::ASCII_8BIT || text.ascii_only?
    end

    def agent_pointer_ok?(value)
      text = value.to_s
      text_encoding_ok?(text) && text.match?(AGENT_POINTER)
    end

    def fileman_date?(value)
      text = value.to_s
      text_encoding_ok?(text) && text.match?(FILEMAN_DATE)
    end

    # Distinct letters from D, F, O (ORWDAL32.m:81). "DD" repeats one.
    def type_ok?(value)
      text = value.to_s
      text_encoding_ok?(text) && text.match?(TYPE) && text.chars.uniq.size == text.size
    end

    # GMRARDT, when present, is a FileMan date (GMRAGUI1.m:137). A caret
    # or control is named earlier, in {unsafe_field}, before type and
    # nature. nil and "" are absent (GMRAGUI1.m:137 $G): not validated.
    def reaction_date_ok?(value)
      return true if omitted?(value)

      fileman_date?(value)
    end

    # A present GMRASEVR is "1", "2" or "3" (ORWDAL32.m:88-89). Integer
    # 1, 2 or 3 is that code. A caret or control is named earlier, in
    # {unsafe_field}, before type and nature. nil and "" are absent
    # (GMRAGUI1.m:137 $G): not validated. Any other value is refused.
    def severity_ok?(value)
      return true if omitted?(value)

      SEVERITY.include?(severity_code(value))
    end

    # The String filed in GMRASEVR, or nil when +value+ is not a String
    # or Integer. SEVERITY#include? then keeps only "1", "2" and "3".
    def severity_code(value)
      case value
      when String, Integer then value.to_s
      end
    end

    # nil or "" is not a filed value. $G of a missing subscript is ""
    # (GMRAGUI1.m:137), so the subscript is left out of OREDITED.
    def omitted?(value)
      value.nil? || value == ""
    end

    # GMRASYMP(n)="ien^text^FileMan date" and GMRACMTS(n)=comment
    # (GMRAGUI1.m:120, :118 stock). Array keys are the two-level
    # subscripts CiaClient#m_subscript / XwbClient#m_subscript encode.
    # nil or "" GMRARDT / GMRASEVR are left out (GMRAGUI1.m:137 $G).
    # Integer severity is filed as the String code.
    def edited_list(allergy)
      edited = {
        "GMRAGNT" => "#{allergy[:agent]}^#{allergy[:agent_pointer]}",
        "GMRATYPE" => allergy[:type],
        "GMRANATR" => allergy[:nature],
        "GMRAORIG" => allergy[:originator].to_s,
        "GMRAORDT" => allergy[:originated_at],
        "GMRAOBHX" => allergy[:observed_or_historical]
      }
      allergy[:symptoms]&.each_with_index do |symptom, idx|
        edited[[ "GMRASYMP", idx + 1 ]] = "#{symptom[:ien]}^#{symptom[:text]}^#{symptom[:date]}"
      end
      allergy[:comments]&.each_with_index do |line, idx|
        edited[[ "GMRACMTS", idx + 1 ]] = line
      end
      edited["GMRARDT"] = allergy[:reaction_date] unless omitted?(allergy[:reaction_date])
      edited["GMRASEVR"] = severity_code(allergy[:severity]) unless omitted?(allergy[:severity])
      edited
    end

    def dispatch(dfn, edited)
      raw = RpmsRpc.client.call_rpc(SAVE_ALLERGY_RPC, "", dfn, edited)
      classify_reply(raw)
    rescue RpmsRpc::Client::FrameTooLongError => e
      # A value the wire would mis-frame is refused before anything is sent
      # (#472); this API's contract is a failure hash, so it says why.
      failure.merge(error: :frame_too_long, message: e.message)
    end

    def failure
      { success: false }
    end

    def classify_reply(raw)
      text = reply_text(raw)
      return { success: false, error: :empty_reply, message: "" } if text.nil?
      return { success: false, error: :malformed_reply, message: raw.to_s } unless text.is_a?(String)

      if (match = text.match(SUCCESS_REPLY))
        note = match[1]
        return { success: true, note_ien: note ? note.to_i : nil }
      end

      if text.start_with?("-1^")
        return { success: false, error: error_for(text), message: text }
      end

      { success: false, error: :malformed_reply, message: text }
    end

    # [], "", and nil are empty. A one-element Array is the single ORY line
    # live XWB/CIA clients return; trailing $C(30)/$C(31) are framing, not
    # data (DataMapper.strip_recordset_separators). Any other non-String —
    # a longer Array, an Integer, a Symbol — is not that line.
    def reply_text(raw)
      return nil if raw.nil? || raw == "" || raw == []

      line = single_reply_line(raw)
      return :malformed unless line.is_a?(String)
      return nil if line.empty?

      stripped = DataMapper.strip_recordset_separators(line)
      stripped.empty? ? nil : stripped
    end

    # One ORY line, or :malformed when the reply is not that line.
    def single_reply_line(raw)
      return raw unless raw.is_a?(Array)
      return raw.first if raw.size == 1 && raw.first.is_a?(String)

      :malformed
    end

    def error_for(text)
      case text
      when DUPLICATE_REPLY then :duplicate
      when LOCK_REPLY then :locked
      when ACTIVE_ALLERGIES_REPLY then :active_allergies
      when ASSESSMENT_UPDATE_REPLY then :assessment_update_failed
      else :rejected
      end
    end
  end
end
