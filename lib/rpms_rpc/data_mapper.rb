# frozen_string_literal: true

require_relative "fileman_date_parser"
require_relative "rcis_wire"

module RpmsRpc
  # Declarative mapping from RPMS RPC caret-delimited responses to hashes.
  #
  # Define a mapping once:
  #
  #   RpmsRpc::DataMapper.define(:patient_select) do |m|
  #     m.rpc "ORWPT SELECT"
  #     m.field 0, :name
  #     m.field 1, :sex
  #     m.field 2, :dob, :fileman_date
  #     m.field 3, :ssn
  #     m.field 14, :age, :integer
  #   end
  #
  # Parse a single-line response:
  #
  #   RpmsRpc::DataMapper[:patient_select].parse_one(response, extras: { dfn: 42 })
  #   # => { name: "DOE,JOHN", sex: "M", dob: #<Date: 1980-01-15>, ssn: "111223333", age: 45, dfn: 42 }
  #
  # Parse a multi-line response (search results):
  #
  #   RpmsRpc::DataMapper[:patient_list].parse_many(response)
  #   # => [{ dfn: 1, name: "DOE,JOHN" }, { dfn: 2, name: "SMITH,JANE" }]
  #
  module DataMapper
    Field = Struct.new(:position, :attribute, :type, :terminology, :pointer, keyword_init: true)

    # BMX GLOBAL-ARRAY (recordset) RPC replies open with a typed column-header
    # row, append a $C(30) record separator to every row, and close with a bare
    # $C(31) (e.g. SEARCH^BSDX24 writes "T00030RESOURCENAME^..."_$C(30), then
    # $C(31)). The parse paths below strip that framing so recordset reads get
    # DATA rows — previously only Scheduling#error_write did, and every
    # fetch_one/fetch_many recordset read parsed the header row as data.
    RECORDSET_SEPARATORS = /[\u001E\u001F]+\z/

    # Trailing $C(30)/$C(31) record/end separators removed.
    def self.strip_recordset_separators(line)
      line.to_s.sub(RECORDSET_SEPARATORS, "")
    end

    # A recordset column-header row: every caret piece is a type char
    # (I/T/D/F) followed by a 5-digit width and the column name (e.g.
    # "I00020APPOINTMENTID^T00020ERRORID"). Data rows never match.
    def self.recordset_header_row?(line)
      s = strip_recordset_separators(line)
      return false if s.empty?

      s.split("^", -1).all? { |piece| piece.match?(/\A[ITDF]\d{5}/) }
    end

    # A broker error row: "-N^message" (ERR^BGOUTL emits -CODE^text —
    # BGOUTL.m:408-409; SELECT^ORWPT emits "-1^^^^^Patient is unknown to
    # CPRS." for a missing DFN — ORWPT.m:49). Never a data record.
    def self.error_row?(line)
      strip_recordset_separators(line).match?(/\A-\d+(?:\.\d+)?\^/)
    end

    # Whether a write whose routine answers nothing on success went through:
    # SET^BGOREF and DEL^BGOPROB leave RET "" (or 0) and an error -CODE^text.
    # A real client hands such a reply back as lines, so an empty RET arrives
    # as [] (CiaClient#call_rpc splits on rows; Client#split_response("") is
    # []), and MockClient as "". A reply that came back with no error row is
    # accepted; nil, a client that answered nothing at all, is not.
    def self.write_accepted?(reply)
      return false if reply.nil?

      Array(reply).none? { |line| error_row?(line.to_s) }
    end

    # A no-data sentinel row: the stock-VistA "^message" convention — an
    # empty first piece carrying a human-readable message in piece 2 with
    # nothing after it. Examples: "^No problems found." (ORQQPL.m:17),
    # "^Problem list not available.^" (ORQQPL.m:18), "^No vitals found."
    # (ORQQVI.m:24), "^No medications found." (ORQQPS.m:53), and the
    # allergy assessment-state markers "^No Allergy Assessment" /
    # "^No Known Allergies" / "^No allergies found." (ORQQAL.m:12-15).
    # Data rows never match: their first piece (IEN/name) is non-empty.
    def self.sentinel_row?(line)
      pieces = strip_recordset_separators(line).split("^", -1)
      return false unless pieces.length >= 2 && pieces[0].empty?
      return false unless pieces[1].match?(/\A[A-Za-z]/)

      pieces[2..].all?(&:empty?)
    end

    # Rows that must never surface as data records.
    def self.non_data_row?(line)
      error_row?(line) || sentinel_row?(line)
    end

    # BSDX reports a trapped list-read failure as a one-column recordset whose
    # header is the ERRORID column (e.g. "T00030ERRORID") and whose data row is
    # the message (#481). A wider header that merely includes ERRORID is data.
    # Any ERRORID header line, wherever it sits, is that failure.
    ERRORID_COLUMN_HEADER = /\A[ITDF]\d{5}ERRORID\z/
    # Leading "<digits>\x00", or a bare "\x00", the GLOBAL ARRAY ack prefix.
    BSDX_ACK_PREFIX = /\A[0-9]*\x00/
    # Leading spaces, U+FFFD and C0 controls. Stripped from every BSDX list
    # line before it is classified, and from a header handed to parsing. A
    # normal data row keeps its bytes: a field may legitimately start with
    # spaces. That flattened or junk-prefixed shape is handled defensively.
    # No current client is known to produce it. CiaClient#parse_cia_reply
    # strips the sequence echo and the \x00 ack before Reply.from_wire, so
    # call_rpc does not flatten those bytes into this prefix.
    BSDX_LIST_HEADER_LEAD = /\A[ \u{FFFD}\x00-\x1F]+/
    BSDX_ERROR_CODE = /\A(-\d+(?:\.\d+)?)\^/

    # A BSDX list read (#481). One normaliser serves both paths. Before any
    # regex, each String chunk is brought to UTF-8: a chunk that is not
    # UTF-8-tagged is duplicated and force-encoded UTF-8, and bytes that are
    # not valid UTF-8 raise ("reply is not valid UTF-8"). A valid binary-tagged
    # reply parses with UTF-8 values. The normaliser then strips a leading
    # "<digits>\x00" (or "\x00") ack and cuts at $C(31), then splits every Array
    # element and every String on $C(30). +split_newlines+ (the call_rpc path,
    # fetch_many_or_raise) also splits on /\r?\n/ — a String with CR/LF and no
    # $C(30)/NUL/$C(31) is a line reply. The recordset path passes false, because
    # fields there hold CR/LF.
    #
    # Every line is classified from the text left after BSDX_LIST_HEADER_LEAD.
    # An error row behind that prefix raises with its numeric code, the same as
    # a plain "-N^…" row. A line that is blank after the strip counts as empty,
    # so a reply of only such lines raises the way a blank line does ("no
    # recordset header"; nil, "" and [] are "empty reply").
    #
    # Returns :empty when the reply is a header-only recordset (a genuine empty
    # result), including a header behind that prefix. A second header line
    # raises ("unexpected second header") instead. Otherwise returns the
    # classified lines: the header with the prefix removed, then each data row
    # in the bytes the normaliser produced. The prefix is stripped for
    # classification and for the header line only. fetch_many_or_raise parses
    # those lines (parse_many skips the header), never the raw response, so a
    # normal row parses exactly as fetch_many / parse_many parse it.
    # Scheduling#recordset parses the same lines, so a flattened header maps
    # columns the same way as an unflattened one.
    #
    # Raises Client::RpcError for nil or an empty reply, an error row "-N^…"
    # anywhere, an ERRORID header line anywhere, more than one header line,
    # bytes that are not valid UTF-8, or a reply that is neither Array nor
    # String. With +split_newlines+ false (the recordset path) a reply with no
    # header row raises ("no recordset header") whether or not it is framed.
    # With +split_newlines+ true, an unframed line list whose every non-blank
    # line contains a caret is still the rows parse_many already returns (a
    # seeded collection has this shape); a non-blank line with no caret raises
    # ("no recordset header"), and a framed reply with no header raises. An
    # ERRORID header line anywhere raises ("ERRORID recordset"); more than one
    # header line otherwise raises ("unexpected second header"). Both paths do.
    # The message names +rpc_name+ and, for a "-N^" row, the numeric code
    # ("broker error -1"), or a fixed phrase ("ERRORID recordset", "empty
    # reply", "no recordset header", "unexpected second header", "reply is not
    # valid UTF-8", "unexpected reply type"). Broker text stays out of the
    # message: it can hold a patient name, and sanitize_error does not catch
    # mixed-case names. The failure is never Encoding::CompatibilityError.
    # DataMapper#fetch_many and #fetch_many_or_nil on these mappings keep the
    # old contract for direct mapper callers. Only the Scheduling methods changed.
    def self.read_bsdx_list!(response, rpc_name, split_newlines: false)
      outcome, detail = classify_bsdx_list_read(response, split_newlines: split_newlines)
      return detail if outcome == :rows
      return :empty if outcome == :empty

      raise Client::RpcError, RpmsRpc.sanitize_error("#{rpc_name}: #{detail}")
    end

    def self.classify_bsdx_list_read(response, split_newlines:)
      return [ :failure, "empty reply" ] if bsdx_list_blank?(response)
      return [ :failure, "unexpected reply type" ] unless response.is_a?(Array) || response.is_a?(String)

      chunks = bsdx_chunks_as_utf8(response)
      return [ :failure, "reply is not valid UTF-8" ] if chunks.nil?

      classified = bsdx_list_lines(chunks, split_newlines: split_newlines).map { |line| bsdx_classify_line(line) }
      if (error = classified.find { |line| line[:kind] == :error })
        return [ :failure, "broker error #{bsdx_error_code(error[:text])}" ]
      end

      present = classified.reject { |line| line[:kind] == :blank }
      headers, data = present.partition { |line| line[:kind] == :header }
      if headers.empty?
        return classify_headerless_bsdx_list(chunks, data, split_newlines: split_newlines)
      end
      return [ :failure, "ERRORID recordset" ] if bsdx_errorid_recordset?(headers)
      return [ :failure, "unexpected second header" ] if headers.size > 1

      data.empty? ? [ :empty, nil ] : [ :rows, bsdx_lines_for_parse(headers, data) ]
    end
    private_class_method :classify_bsdx_list_read

    # No [ITDF]NNNNN row. The recordset path (split_newlines: false) raises
    # whether or not the reply is framed. fetch_many_or_raise keeps an unframed
    # line list when every non-blank line contains a caret — the rows parse_many
    # already returns (a seeded collection has this shape). A non-blank line
    # with no caret raises ("no recordset header"), and so does a framed reply.
    def self.classify_headerless_bsdx_list(chunks, data, split_newlines:)
      return [ :failure, "no recordset header" ] unless split_newlines
      return [ :failure, "no recordset header" ] if data.empty? || bsdx_recordset_framed?(chunks)
      return [ :failure, "no recordset header" ] if data.any? { |line| !line[:text].include?("^") }

      [ :rows, data.map { |line| line[:original] } ]
    end
    private_class_method :classify_headerless_bsdx_list

    def self.bsdx_list_blank?(response)
      response.nil? || response == "" || (response.is_a?(Array) && response.empty?)
    end
    private_class_method :bsdx_list_blank?

    # Chunks retagged UTF-8, or nil when any String's bytes are not valid
    # UTF-8. Runs before every regex in this classifier. A chunk that is not
    # UTF-8-tagged is duplicated and force-encoded, so the caller's string is
    # left alone and a binary chunk cannot raise Encoding::CompatibilityError.
    # The failure phrase is fixed ("reply is not valid UTF-8") and carries no
    # broker text.
    def self.bsdx_chunks_as_utf8(response)
      raw = response.is_a?(Array) ? response : [ response ]
      converted = []
      raw.each do |chunk|
        text, valid = bsdx_chunk_as_utf8(chunk)
        unless valid
          converted = nil
          break
        end

        converted << text
      end
      converted
    end
    private_class_method :bsdx_chunks_as_utf8

    def self.bsdx_chunk_as_utf8(chunk)
      return [ chunk, true ] unless chunk.is_a?(String)

      text = chunk.encoding == Encoding::UTF_8 ? chunk : chunk.dup.force_encoding(Encoding::UTF_8)
      [ text, text.valid_encoding? ]
    end
    private_class_method :bsdx_chunk_as_utf8

    def self.bsdx_list_lines(chunks, split_newlines:)
      chunks.flat_map { |chunk| bsdx_normalize_chunk(chunk.to_s, split_newlines: split_newlines) }
    end
    private_class_method :bsdx_list_lines

    def self.bsdx_normalize_chunk(text, split_newlines:)
      text = text.sub(BSDX_ACK_PREFIX, "")
      text = text.split("\x1f", 2).first.to_s
      parts = text.split("\x1e")
      return parts unless split_newlines

      parts.flat_map { |part| part.split(/\r?\n/) }
    end
    private_class_method :bsdx_normalize_chunk

    def self.bsdx_recordset_framed?(chunks)
      chunks.any? { |chunk| chunk.to_s.match?(/[\x00\x1e\x1f]/) }
    end
    private_class_method :bsdx_recordset_framed?

    # One normalised line, classified from the text left after the lead strip.
    # :original is the normaliser's line. A normal data row is handed to
    # parsing as that string; a header is handed as :text.
    def self.bsdx_classify_line(line)
      text = bsdx_classify_text(line)
      kind = if text.empty?
        :blank
      elsif error_row?(text)
        :error
      elsif bsdx_list_header?(text)
        :header
      else
        :data
      end
      { original: line, text: text, kind: kind }
    end
    private_class_method :bsdx_classify_line

    # The stripped header, then each data row's original bytes. Leading spaces
    # on a normal row are field content, so only the header line is stripped
    # on the way to the parser.
    def self.bsdx_lines_for_parse(headers, data)
      [ headers.first[:text], *data.map { |line| line[:original] } ]
    end
    private_class_method :bsdx_lines_for_parse

    # +text+ is bsdx_classify_text's result, not the raw line. recordset_header_row?
    # is unchanged, so fetch_many still parses a junk-prefixed header as a
    # record for a direct mapper caller.
    def self.bsdx_list_header?(text)
      return false if text.empty?

      text.split("^", -1).all? { |piece| piece.match?(/\A[ITDF]\d{5}/) }
    end
    private_class_method :bsdx_list_header?

    def self.bsdx_classify_text(line)
      strip_recordset_separators(line).sub(BSDX_LIST_HEADER_LEAD, "")
    end
    private_class_method :bsdx_classify_text

    def self.bsdx_error_code(text)
      strip_recordset_separators(text)[BSDX_ERROR_CODE, 1]
    end
    private_class_method :bsdx_error_code

    # Any one-column ERRORID header, not only a recordset whose every header
    # is that column. A wider header that merely includes ERRORID does not match.
    def self.bsdx_errorid_recordset?(headers)
      headers.any? { |line| line[:text].match?(ERRORID_COLUMN_HEADER) }
    end
    private_class_method :bsdx_errorid_recordset?

    class Mapping
      attr_reader :name, :rpc_name, :fields

      def initialize(name)
        @name = name
        @rpc_name = nil
        @fields = []
      end

      # Configure this mapping using a block.
      # Uses instance_exec so the block can call rpc/field directly.
      # Safe: blocks are developer-defined at load time, not user input.
      def configure(&block)
        instance_exec(&block) # rubocop:disable Security/Eval
      end

      def rpc(name)
        @rpc_name = name
      end

      def field(position, attribute, type = :string, terminology: nil, pointer: nil)
        @fields << Field.new(position: position, attribute: attribute, type: type,
                             terminology: terminology, pointer: pointer)
      end

      # Declare a line-based field (one field per response line, not per caret).
      # Used for RPCs like XUS AV CODE where each line has a distinct meaning.
      # The fields of a line-based mapping (one field per LINE), or [].
      def line_fields
        @line_fields || []
      end

      def line_fields?
        line_fields.any?
      end

      def line_field(line_number, attribute, type = :string)
        @line_fields ||= []
        @line_fields << Field.new(position: line_number, attribute: attribute, type: type)
      end

      # Declare a scalar response (single value, no structure).
      # Used for RPCs like ORWPT DIEDON that return one value.
      def scalar(attribute, type = :string)
        @scalar_attribute = attribute
        @scalar_type = type
      end

      # Declare that this mapping models status/error replies as data —
      # "-1^message" (and rows whose leading piece is legitimately empty)
      # ARE the record (e.g. a write RPC's "-1^error text" rejection).
      # Such mappings bypass the non_data_row? guard that otherwise keeps
      # broker error rows and "^message" sentinels out of parsed records.
      def status_reply!
        @status_reply = true
      end

      def status_reply?
        @status_reply == true
      end

      # Declare an RCIS (BMC) record mapping (#210). CRTMSG^BMCRPC4 opens
      # every record line with the sigil "~`" (BMCRPC4.m:60,116), so a line
      # without it is a message, not a record (e.g. "Not a valid Referral
      # Ien", BMCRPC1.m:55). A further "~`" in the line starts the sections
      # appended after the fields; with +sections+ they are parsed by
      # RcisWire.sections into that attribute.
      def rcis_record!(sections: nil)
        @rcis_record = true
        @rcis_sections = sections
      end

      def rcis_record?
        @rcis_record == true
      end

      # Declare a text blob response (array of lines joined with newlines).
      # Used for RPCs like ORWRP REPORT TEXT that return free text.
      def text_blob(attribute)
        @text_attribute = attribute
      end

      # Row hook (result hash, caret pieces). Must return the row. Used when
      # a piece is a marker whose parsed value is not the raw token.
      def after_row(&block)
        @after_row = block
      end

      # Format hook (caret pieces, source attrs). Must return the pieces.
      # A mapping uses it when the wire token for a marker is not what
      # format_value emits from the parsed attribute. Mappings that do not
      # declare one keep format_value's output.
      def format_row(&block)
        @format_row = block
      end

      def text_blob?
        !@text_attribute.nil?
      end

      def scalar?
        !@scalar_attribute.nil?
      end

      def terminology_fields
        @fields.select { |f| !f.terminology.nil? }
      end

      def pointer_fields
        @fields.select { |f| !f.pointer.nil? }
      end

      # Parse a single-line RPC response into a hash. Broker error rows
      # ("-N^message") and no-data sentinel rows ("^message") return nil —
      # they are not records (see DataMapper.non_data_row?).
      def parse_one(response, extras: {})
        line = normalize_line(response)
        return nil if line.nil? || line.empty?

        if rcis_record?
          return nil unless line.start_with?(RcisWire::SIGIL)

          line, rest = line.delete_prefix(RcisWire::SIGIL).split(RcisWire::SIGIL, 2)
        end
        return nil if !status_reply? && DataMapper.non_data_row?(line)

        parts = line.split("^", -1)
        result = {}

        @fields.each do |f|
          raw = parts[f.position]
          result[f.attribute] = coerce(raw, f.type)
        end
        result[@rcis_sections] = RcisWire.sections(rest) if @rcis_sections
        result = instance_exec(result, parts, &@after_row) if @after_row # rubocop:disable Security/Eval

        extras.each { |k, v| result[k] = v }
        result
      end

      # Parse a multi-line RPC response into an array of hashes.
      # Brokers occasionally return a bare String where a list is expected —
      # previously that crashed on String#filter_map. A broker error string
      # ("-1^message") yields no rows (never a bogus record built from the
      # error text); any other String is split into its lines.
      def parse_many(response)
        return [] if response.nil? || response.empty?

        if response.is_a?(String)
          return [] if response.start_with?("-1^")

          response = response.split(/\r?\n/)
        end
        response.filter_map do |line|
          next if line.nil? || line.to_s.empty?
          next if DataMapper.recordset_header_row?(line)
          next if !status_reply? && DataMapper.non_data_row?(line)
          parse_one(line)
        end
      end

      # parse_many, with an `altered:` flag on every row (rpms-rpc#463).
      # `lines` are the response's lines; `altered_indexes` are the zero-based
      # ones whose text had a byte replaced (Reply.lines_with_altered builds
      # both from any reply). Each line is parsed on its own, which is what
      # parse_many does anyway, so a row's flag is its own line's and never
      # its neighbour's. The key is additive: a clean row says altered: false.
      def parse_many_flagged(lines, altered_indexes = [])
        lines.each_with_index.flat_map do |line, index|
          parse_many([ line ]).map { |row| row.merge(altered: altered_indexes.include?(index)) }
        end
      end

      # Parse a line-based response where each LINE is a different field.
      def parse_lines(response, extras: {})
        return nil if response.nil? || response.empty?

        # NEVER index a String by field position — String#[] returns
        # CHARACTERS, so a raw reply would parse framing bytes as fields.
        # A String here is split into lines; transports with a richer reply
        # grammar must pre-split via Client#call_rpc_lines.
        response = response.split(/\r\n|\r|\n/) if response.is_a?(String)

        result = {}
        (@line_fields || []).each do |f|
          raw = response[f.position]
          result[f.attribute] = raw.nil? ? nil : coerce(raw.to_s, f.type)
        end

        extras.each { |k, v| result[k] = v }
        result
      end

      # Parse a scalar response (single value).
      def parse_scalar(response)
        line = normalize_line(response)
        return nil if line.nil? || line.empty?

        coerce(line, @scalar_type || :string)
      end

      # Parse a text blob response (join lines with newlines).
      def parse_text(response)
        return nil if response.nil?
        return nil if response.is_a?(Array) && response.empty?
        return response if response.is_a?(String) && !response.empty?
        return nil if response.is_a?(String) && response.empty?

        response.join("\n")
      end

      # -- format_* methods: reverse of parse (hash → caret-delimited string) ----

      # Format a hash into a caret-delimited string matching this mapping's field positions.
      # A position may be declared twice (attribute alias — two attribute
      # names reading the same piece); an alias the caller didn't
      # seed must not blank out the value another alias wrote, so a
      # position claimed by a seeded attribute is only overwritten by
      # another seeded attribute.
      def format_one(attrs)
        max_pos = @fields.map(&:position).max || 0
        parts = Array.new(max_pos + 1, "")
        claimed = {}

        @fields.each do |f|
          next if claimed[f.position] && !attrs.key?(f.attribute)

          parts[f.position] = format_value(attrs[f.attribute], f.type)
          claimed[f.position] = true if attrs.key?(f.attribute)
        end

        parts = instance_exec(parts, attrs, &@format_row) if @format_row # rubocop:disable Security/Eval

        line = parts.join("^")
        rcis_record? ? RcisWire::SIGIL + line : line
      end

      # Format an array of hashes into an array of caret-delimited strings.
      def format_many(attrs_list)
        attrs_list.map { |attrs| format_one(attrs) }
      end

      # Format a scalar value for this mapping's scalar type.
      def format_scalar(value)
        format_value(value, @scalar_type || :string)
      end

      # -- fetch_* methods: call RPC + parse in one shot -------------------------
      #
      # All fetch methods use RpmsRpc.client (configured at boot or via RpmsRpc.mock!).

      def fetch_one(*params, extras: {})
        response = RpmsRpc.client.call_rpc(rpc_name, *params)
        return nil if response.nil? || response.empty?

        parse_one(response, extras: extras)
      end

      def fetch_many(*params)
        response = RpmsRpc.client.call_rpc(rpc_name, *params)
        return [] if response.nil? || response.empty?

        parse_many(response)
      end

      # fetch_many, but a FAILED read is nil instead of []. fetch_many
      # cannot tell "nothing on file" from "the broker refused" — both come
      # back empty — which is fine for a list a caller only renders, and
      # wrong wherever the difference is clinical (a patient with no
      # recorded weight vs a weight we could not read). Returns nil when the
      # broker gave nothing or an error row ("-N^message"), otherwise the
      # parsed rows, [] included.
      def fetch_many_or_nil(*params)
        response = RpmsRpc.client.call_rpc(rpc_name, *params)
        return nil if response.nil? || response.empty?

        first = response.is_a?(String) ? response.split(/\r?\n/).first : response.first
        return nil if !first.nil? && DataMapper.error_row?(first.to_s)

        parse_many(response)
      end

      # fetch_many for a BSDX recordset list (#481). See DataMapper.read_bsdx_list!.
      # Parses the classified lines, never the raw response. The header is the
      # prefix-stripped header, which parse_many skips, so a junk-prefixed
      # header is never a record. A normal data row keeps its bytes and parses
      # exactly as fetch_many / parse_many parse it. A header-only reply is [].
      # An unframed headerless line list whose every non-blank line contains a
      # caret is still those rows; a non-blank line with no caret raises. A
      # valid binary-tagged reply parses with UTF-8 values. This does not
      # change fetch_many or fetch_many_or_nil: on these mappings they keep the
      # old contract for direct mapper callers. Only the Scheduling methods changed.
      def fetch_many_or_raise(*params)
        response = RpmsRpc.client.call_rpc(rpc_name, *params)
        lines = DataMapper.read_bsdx_list!(response, rpc_name, split_newlines: true)
        return [] if lines == :empty

        parse_many(lines)
      end

      def fetch_scalar(*params)
        response = RpmsRpc.client.call_rpc(rpc_name, *params)
        return nil if response.nil? || response.empty?

        parse_scalar(response)
      end

      def fetch_text(*params)
        response = RpmsRpc.client.call_rpc(rpc_name, *params)
        return nil if response.nil? || response.empty?

        parse_text(response)
      end

      def fetch_lines(*params, extras: {})
        client = RpmsRpc.client
        # Line-positional parsing needs LINES, split by the transport's own
        # reply grammar. A client whose call_rpc returns a String would be
        # read character by character (sequence echo "2" + ACK -> DUZ 2,
        # error 0, success), so ask for lines when the client offers them.
        response = if client.respond_to?(:call_rpc_lines)
          client.call_rpc_lines(rpc_name, *params)
        else
          client.call_rpc(rpc_name, *params)
        end
        return nil if response.nil? || response.empty?

        parse_lines(response, extras: extras)
      end

      private

      def format_value(val, type)
        return "" if val.nil?

        case type
        when :fileman_date
          val.is_a?(Date) || val.is_a?(Time) ? FilemanDateParser.format_date(val) : val.to_s
        when :fileman_datetime
          # DateTime < Date, so the timed classes match first; a bare Date has
          # no time of day and format_datetime would call #hour on it. FileMan
          # stores a date-only value here as "3250115" -- which the parse side
          # already accepts -- so emit that rather than raising. (#267)
          case val
          when DateTime, Time then FilemanDateParser.format_datetime(val)
          when Date then FilemanDateParser.format_date(val)
          else val.to_s
          end
        when :external_date
          val.is_a?(Date) || val.is_a?(Time) ? FilemanDateParser.format_external_date(val) : val.to_s
        when :external_datetime
          # Same shape, quieter failure: a bare Date fell through to #to_s and
          # put an ISO string ("2026-01-15") on a wire that expects the
          # external form, instead of raising where anyone would see it.
          case val
          when DateTime, Time then FilemanDateParser.format_external_datetime(val)
          when Date then FilemanDateParser.format_external_date(val)
          else val.to_s
          end
        when :integer
          val.to_s
        when :boolean
          val ? "1" : "0"
        else
          val.to_s
        end
      end

      # First DATA line of a response: recordset header rows and $C(30)/$C(31)
      # separators (see RECORDSET_SEPARATORS) are not data.
      def normalize_line(response)
        return nil if response.nil?
        return nil if response.is_a?(String) && response.empty?

        if response.is_a?(Array)
          return response.lazy
                         .map { |l| DataMapper.strip_recordset_separators(l) }
                         .reject { |l| l.empty? || DataMapper.recordset_header_row?(l) }
                         .first
        end

        DataMapper.strip_recordset_separators(response)
      end

      def coerce(raw, type)
        return nil if raw.nil? || raw.empty?

        case type
        when :string
          raw
        when :integer
          raw.to_i
        when :float
          Float(raw)
        when :fileman_date
          FilemanDateParser.parse_date(raw)
        when :fileman_datetime
          # Date/time fields carry date-only values when no time was
          # recorded ("3250115" vs "3250115.0800") — fall back to a
          # midnight Time rather than dropping the value. Always Time,
          # never Date, so the mapped type is consistent for callers.
          FilemanDateParser.parse_datetime_or_date(raw)
        when :external_date
          FilemanDateParser.parse_external_date(raw)
        when :external_datetime
          FilemanDateParser.parse_external_datetime(raw)
        when :boolean
          raw == "1" || raw.casecmp?("yes")
        else
          raw
        end
      end
    end

    @registry = {}

    def self.define(name, &block)
      mapping = Mapping.new(name)
      if block.arity == 1
        block.call(mapping)
      else
        mapping.configure(&block)
      end
      @registry[name] = mapping
      mapping
    end

    def self.[](name)
      @registry.fetch(name)
    end

    def self.method_missing(name, ...)
      return @registry.fetch(name) if @registry.key?(name)

      super
    end

    def self.respond_to_missing?(name, include_private = false)
      @registry.key?(name) || super
    end
  end
end
