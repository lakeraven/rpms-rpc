# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"
require_relative "../reply"

module RpmsRpc
  # Symbolic API for the FileMan Delphi Components RPC family (DDR*) — the
  # stock-VistA generic FileMan CRUD surface. Engine code (and the composed
  # RpmsRpc::Registration flow) calls these methods instead of hand-building
  # DDR list params or parsing the bracket-marker reply grammars.
  #
  # Wire contracts are cited per method from the bcer-9.0-ydb corpus
  # (rpms-ops/data/standup/bcer-9.0-ydb/r/): LISTC^DDR, LOCKC^DDR1,
  # GETSC^DDR2, FILEC^DDR3, VALC^DDR3. All DDR RPCs take LIST params;
  # the *_param / *_params builders are public so tests and mocks can seed
  # against the exact payload each RPC receives.
  #
  # Result contract (mirrors the other api/ write modules): a parsed Hash on
  # any broker reply, nil when the broker gives no response at all, so
  # callers can distinguish "rejected" from "unreachable".
  module DdrFileman
    extend self
    extend Shape::Declarable

    # -- DDR FILER -----------------------------------------------------------

    # File field values through UPDATE^DIE (mode "ADD" — also edits existing
    # IENS rows) or FILE^DIE (any other mode) — FILEC^DDR3: DDR3.m:14-18.
    #
    #   mode:  "ADD" or "EDIT"
    #   rows:  [{ file:, field:, iens:, value: }, ...] — each becomes a
    #          DDRROOT(n) row "FILE^FIELD^IENS^VALUE"; VALUE is pieces 4-99,
    #          so values containing "^" survive (FDASET^DDR3: DDR3.m:29-34).
    #          Values are FileMan-INTERNAL (pointer IENs, internal set
    #          codes): UPDATE^DIE/FILE^DIE run with no "E" flag
    #          (DDR3.m:15,18)
    #   iens:  { placeholder_number => ien } pins "+n," placeholders to
    #          specific (e.g. DINUM) IENs (FILEC^DDR3: DDR3.m:12-13)
    #   flags: FILE^DIE flags for non-ADD modes (DDR3.m:17-18)
    #
    # Returns { success:, iens: {n=>ien}, errors: [..] } or nil (no response).
    # :iens carries the resolved "+n,^IEN" placeholder rows (DDR3.m:20-22).
    # That parse is unchanged when the reply is not a completed call.
    # FILEC^DDR3 emits "[Data]" first on a completed call (DDR3.m:19-23).
    # success is true only when the reply contains "[Data]" and the
    # [BEGIN_diERRORS] block is empty. A reply with no "[Data]" is
    # success: false; errors names the missing marker and includes the
    # reply's first line. nil when the broker gives no response. Callers
    # (sex_edit, filer_outcome, SchedulingSetup) use this success flag and
    # do not re-check the marker.
    def filer(mode:, rows:, iens: {}, flags: "")
      reply = lines(call(:ddr_filer, *filer_params(mode: mode, rows: rows, iens: iens, flags: flags)))
      return nil if reply.nil?

      resolved = reply.filter_map { |l| l.match(/\A\+(\d+),\^(.*)\z/) }
                      .to_h { |md| [ md[1].to_i, md[2] ] }
      errors = error_block(reply)
      data = reply.any? { |line| line.include?("[Data]") }
      errors = [ "no [Data] marker in DDR FILER reply: #{reply.first}" ] + errors unless data
      { success: data && errors.empty?, iens: resolved, errors: errors }
    rescue RpmsRpc::Client::FrameTooLongError => e
      # A value the wire would mis-frame is refused before anything is sent
      # (#472): nothing was filed, and the errors array says why.
      { success: false, iens: {}, errors: [ e.message ] }
    end

    def filer_params(mode:, rows:, iens: {}, flags: "")
      root = rows.each_with_index.to_h do |row, i|
        [ i + 1, "#{row[:file]}^#{row[:field]}^#{row[:iens]}^#{row[:value]}" ]
      end
      [ mode.to_s, root, flags.to_s, iens.transform_keys(&:to_i).transform_values(&:to_s) ]
    end

    # -- DDR LISTER ----------------------------------------------------------

    # List file entries via LIST^DIC. Criteria mirror PARSE^DDR
    # (DDR.m:53-65); nil criteria are omitted (the server $G-defaults them;
    # MAX defaults to "*" — DDR.m:58).
    #
    # Returns { entries: [{ien:, pieces: [..]}], more: {value:, ien:}|nil,
    # error: bool, data: bool } or nil (no response). :data is true when
    # the reply opened a data section and false when it did not. A data
    # section is the V0 marker "[Data]" or the V1 marker "[BEGIN_diDATA]".
    # With a data section, :entries are the packed IEN-first rows, and
    # :more and :error are the continuation and error flags. V1 rows are
    # the lines between "[BEGIN_diDATA]" and "[END_diDATA]";
    # "[END_diDATA]" is not a row. With no data section, :entries is
    # empty, and any line that is not a bracket marker and not a "MORE^"
    # continuation is an error: a bare broker line is not a confirmed
    # empty list.
    # Reply grammar is optional "[Misc]" + "MORE^from^ien", then one of
    # two shapes. V0, over the CIA broker (XWBAPVER is unset —
    # ACTR^CIANBACT reads it from the frame's VER field, CIANBACT.m:67,
    # which RPC frames don't carry): "[Data]" + packed rows, "[Errors]"
    # (V0^DDR: DDR.m:21-30,45). V1, over XwbClient, which sends RPC
    # version "1" so XWBAPVER>0: "[BEGIN_diDATA]", packed rows,
    # "[END_diDATA]", and errors as "[BEGIN_diERRORS]" (V1^DDR:
    # DDR.m:31-41). NB: the exact packed-row column set rides
    # LIST^DIC's "P" output; parse row pieces defensively.
    def lister(file:, iens: nil, fields: nil, flags: nil, max: nil, from: nil,
               part: nil, xref: nil, screen: nil, id: nil, options: nil)
      param = lister_param(file: file, iens: iens, fields: fields, flags: flags, max: max,
                           from: from, part: part, xref: xref, screen: screen, id: id,
                           options: options)
      reply = lines(call(:ddr_lister, param))
      return nil if reply.nil?

      parse_lister_reply(reply)
    end

    def lister_param(file:, iens: nil, fields: nil, flags: nil, max: nil, from: nil,
                     part: nil, xref: nil, screen: nil, id: nil, options: nil)
      # Key order mirrors PARSE^DDR's read order (DDR.m:53-65).
      {
        "FILE" => file, "IENS" => iens, "FIELDS" => fields, "FLAGS" => flags,
        "MAX" => max, "FROM" => from, "PART" => part, "XREF" => xref,
        "SCREEN" => screen, "ID" => id, "OPTIONS" => options
      }.compact.transform_values(&:to_s)
    end

    # -- DDR LOCK/UNLOCK NODE ------------------------------------------------

    # Incremental M LOCK on a global node ('L +node:timeout',
    # LOCKC^DDR1: DDR1.m:21-24). True iff the lock was acquired within
    # `timeout` seconds; false on timeout, nil on no broker response.
    def lock(node:, timeout: 5)
      DataMapper.ddr_lock_unlock_node.fetch_scalar(lock_param(node: node, timeout: timeout))
    end

    # Release the lock ('L -node' — always "1", DDR1.m:25-27).
    def unlock(node:)
      DataMapper.ddr_lock_unlock_node.fetch_scalar(unlock_param(node: node)) == true
    end

    def lock_param(node:, timeout: 5)
      { "NODE" => node.to_s, "LOCKMODE" => "1", "TIMEOUT" => timeout.to_s }
    end

    def unlock_param(node:)
      # Unlock branch = LOCKMODE absent/false (DDR1.m:25-27)
      { "NODE" => node.to_s }
    end

    # -- DDR GETS ENTRY DATA -------------------------------------------------

    GETS_ENTRY_MARKERS = [ "[Data]", "[ERROR]" ].freeze
    # BehavioralHealth::Wellness::VISIT_FIELDS. Copied so this file does not
    # load Wellness (wellness.rb loads ddr_fileman). A FLAGS "I" word-processing
    # block on one of these fields is stray once it holds a text line or closes
    # with $$END$$. A header alone stays { text: [] }.
    FLAGS_I_WORD_PROCESSING_FIELDS = %w[
      .08 1112 1401 1402 1403 1404 1405 1406 1407 1408 1409 1410 1501 1601 1701 1901 2001
    ].freeze
    # Free-text screening comments. GETSC^DDR2 (DDR2.m:32,42) emits each
    # non-word-processing row as FILE^IENS^FIELD^I^E, the caret before E
    # unconditional. With FLAGS "I" only, E is empty, so a row is
    # FILE^IENS^FIELD^INTERNAL^ (five or more pieces, last piece empty).
    # A caret in the stored comment is part of internal. A last piece that
    # is not empty, including a four-piece row, is stray.
    FLAGS_I_COMMENT_FIELDS = %w[1501 1601 1701 1901 2001].freeze
    private_constant :GETS_ENTRY_MARKERS, :FLAGS_I_WORD_PROCESSING_FIELDS, :FLAGS_I_COMMENT_FIELDS

    # Read field values via GETS^DIQ. Default (no OPTIONS) reply format:
    # "[Data]" then "FILE^IEN^FIELD^INTERNAL^EXTERNAL" rows (word-processing
    # fields become "...^[WORD PROCESSING]" + text + "$$END$$"), "[ERROR]"
    # marker when DDRERR is set (GETSC^DDR2 + tags 1/2: DDR2.m:22-43,61).
    # GETSC^DDR2 emits only those two markers.
    #
    # Returns { fields: { "FIELD#" => {internal:, external:} }, error: bool,
    # malformed: bool } or nil (no response). Word-processing fields yield
    # {text: [lines]}. error is true when the reply includes "[ERROR]", or
    # when no field row parsed and the reply has no "[Data]" marker.
    # malformed is true exactly when the reply has neither "[Data]" nor
    # "[ERROR]" and no fields parsed, and false otherwise. An "[ERROR]"
    # reply and an empty "[Data]" section are not malformed. A reply that
    # parses no field rows and carries no "[Data]" marker is still an
    # error: broker/M error strings ("-1^...", raw error text) don't match
    # the FILE^IENS^FIELD^... grammar, and silently returning empty fields
    # would let callers fabricate "value absent" from "read failed".
    # altered: true is added when RpmsRpc::Reply.altered? of the raw reply
    # is true, read before the lines are split, so a client that replaced
    # a control character stays visible after that split drops the flag.
    # A plain String or Array is not altered. "[Data]" is a marker only as
    # the first line of the reply; any later "[Data]" sets stray. "[ERROR]"
    # stays a marker. Outside a word-processing block, any other line that
    # starts with "[" sets stray and is skipped; lines after it are parsed
    # normally. A line with fewer than four caret pieces sets stray and is
    # skipped. GETSC^DDR2 (DDR2.m:32,42) emits each non-word-processing row
    # as FILE^IENS^FIELD^I^E, the caret before E unconditional. With FLAGS
    # "I" only, E is empty. On that read, a non-word-processing visit
    # comment field (1501, 1601, 1701, 1901, 2001) with at least five pieces
    # and an empty last piece stores internal as the pieces from the fourth
    # through the one before the last, joined by "^", and external as "".
    # A caret in the stored comment is recovered. A last piece that is not
    # empty, including a four-piece row, sets stray and is still stored.
    # Other flags, and other fields, are unchanged. Word-processing rows
    # follow the rules below. A second row for a field already parsed, plain
    # or word-processing, sets stray, and the later row replaces the stored
    # value. A "[WORD PROCESSING]" row read
    # with FLAGS "I" whose field is in word_processing_stray_fields (the
    # visit screening fields, when the caller does not pass a set) sets
    # stray once the block holds a text line or closes with "$$END$$". A
    # header with no text line and no terminator stays { text: [] } and is
    # not stray. A block still open at the end of the reply that already
    # holds a text line sets stray for any field. A closed block on a field
    # outside that set is unchanged. :stray and :altered are omitted when
    # false, so a well-formed reply keeps the previous hash. fields, error,
    # and malformed are unchanged either way.
    # The broker reply is parsed by parse_gets_reply.
    def gets_entry(file:, iens:, fields:, flags: "", word_processing_stray_fields: nil)
      parse_gets_reply(call(:ddr_gets_entry_data,
        gets_entry_param(file: file, iens: iens, fields: fields, flags: flags)),
        flags: flags, word_processing_stray_fields: word_processing_stray_fields)
    end
    shape :gets_entry, resource: "files", verb: "GET", path: "/files/{file}/entries/{iens}"

    # GETSC^DDR2's default reply (DDR2.m:22-43,61), the parser gets_entry
    # uses. `raw` is the broker reply or the lines already split from it.
    # flags and word_processing_stray_fields are the ones gets_entry was
    # called with (see its rules above). Nil when there is no reply. Sends
    # nothing.
    def parse_gets_reply(raw, flags: "", word_processing_stray_fields: nil)
      altered = Reply.altered?(raw)
      reply = lines(raw)
      return nil if reply.nil?

      internal_only = flags.to_s == "I"
      stray_wp = internal_only ? word_processing_fields(word_processing_stray_fields) : []
      result = {}
      wp_field = nil
      wp_text = false
      stray = false
      reply.each_with_index do |line, index|
        if wp_field
          if line == "$$END$$"
            stray = true if stray_wp.include?(wp_field)
            wp_field = nil
            wp_text = false
          else
            result[wp_field][:text] << line
            wp_text = true
            stray = true if stray_wp.include?(wp_field)
          end
          next
        end
        if line.start_with?("[")
          # [Data] counts only on the first line. [ERROR] counts anywhere.
          stray = true unless GETS_ENTRY_MARKERS.include?(line) && (line != "[Data]" || index.zero?)
          next
        end

        pieces = line.split("^", -1)
        if pieces.length < 4
          stray = true
          next
        end
        field = pieces[2]
        if pieces[3] == "[WORD PROCESSING]"
          stray = true if result.key?(field)
          result[field] = { text: [] }
          wp_field = field
          wp_text = false
        else
          stray = true if result.key?(field)
          entry = { internal: pieces[3], external: pieces[4..].join("^") }
          if internal_only && flags_i_comment_row_stray?(field, pieces)
            stray = true
          elsif internal_only && FLAGS_I_COMMENT_FIELDS.include?(field)
            entry = { internal: pieces[3..-2].join("^"), external: "" }
          end
          result[field] = entry
        end
      end
      stray = true if wp_field && wp_text
      error = reply.include?("[ERROR]") ||
              (result.empty? && !reply.include?("[Data]"))
      malformed = result.empty? && !reply.include?("[Data]") && !reply.include?("[ERROR]")
      parsed = { fields: result, error: error, malformed: malformed }
      parsed[:altered] = true if altered
      parsed[:stray] = true if stray
      parsed
    end

    def gets_entry_param(file:, iens:, fields:, flags: "")
      param = { "FILE" => file.to_s, "IENS" => iens.to_s, "FIELDS" => fields.to_s }
      param["FLAGS"] = flags.to_s unless flags.to_s.empty?
      param
    end

    # -- DDR VALIDATOR -------------------------------------------------------

    # Validate one field value via VAL^DIE ("EH" flags server-side). Reply
    # lines: "[FILLER]", "[Data]", the internal result ("^" when the value
    # fails the input transform), the external form, then optional error /
    # help blocks (VALC^DDR3: DDR3.m:37-51).
    #
    # Returns { valid:, internal:, external:, errors: [..] } or nil.
    def validate_field(file:, iens:, field:, value:)
      reply = lines(call(:ddr_validator,
        validator_param(file: file, iens: iens, field: field, value: value)))
      return nil if reply.nil?

      data_at = reply.index("[Data]")
      internal = data_at ? reply[data_at + 1].to_s : "^"
      external = data_at ? reply[data_at + 2].to_s : ""
      errors = error_block(reply)
      { valid: internal != "^" && errors.empty?, internal: internal,
        external: external, errors: errors }
    end

    def validator_param(file:, iens:, field:, value:)
      { "FILE" => file.to_s, "IENS" => iens.to_s, "FIELD" => field.to_s, "VALUE" => value.to_s }
    end

    # -- DDR KEY VALIDATOR ---------------------------------------------------

    # Check that a set of field values would satisfy the file's FileMan KEYs
    # (uniqueness) via $$KEYVAL^DIEVK. One list param: odd rows
    # "FILE^IENS^FIELD", the following even row that field's value
    # (FDASET2^DDR4: DDR4.m:10-19). The server strips CR, LF and commas from
    # each value (DDR4.m:18). Reply DDROUT(1): "1" keys valid, "0" not
    # (KEYVAL^DDR4: DDR4.m:4-8). Reads only; nothing is filed.
    #
    # Returns { valid:, error: } or nil (no response). Any reply other than
    # "1"/"0" (e.g. an M error text) is valid: false with the text in :error.
    # NB: the pinned bcer-9.0 #8994 entry points at KEYVAL^DDR3, a label that
    # does not exist, so the live broker currently answers LABELMISSING.
    def validate_key(values:)
      reply = lines(call(:ddr_key_validator, key_validator_param(values: values)))
      return nil if reply.nil?

      verdict = reply.first.strip
      return { valid: verdict == "1", error: nil } if %w[0 1].include?(verdict)

      { valid: false, error: reply.join("\n") }
    end

    def key_validator_param(values:)
      values.each_with_index.each_with_object({}) do |(v, i), param|
        param[(2 * i + 1).to_s] = "#{v[:file]}^#{v[:iens]}^#{v[:field]}"
        param[(2 * i + 2).to_s] = v[:value].to_s
      end
    end

    private

    def word_processing_fields(passed)
      Array(passed || FLAGS_I_WORD_PROCESSING_FIELDS).map(&:to_s)
    end

    # A FLAGS "I" comment row is stray unless it is the GETSC^DDR2 shape
    # (DDR2.m:32,42): at least five pieces and an empty last piece. A
    # four-piece row has no empty external piece, so it is stray.
    def flags_i_comment_row_stray?(field, pieces)
      FLAGS_I_COMMENT_FIELDS.include?(field) &&
        (pieces.length < 5 || !pieces.last.empty?)
    end

    def call(mapping_name, *params)
      RpmsRpc.client.call_rpc(DataMapper[mapping_name].rpc_name, *params)
    end

    # V0 rows are every non-marker, non-MORE line. V1 rows are only the
    # lines inside "[BEGIN_diDATA]" ... "[END_diDATA]". An error marker
    # closes a V1 data section so its text is not a row. No data section
    # yields no entries, and a stray line there is an error.
    def parse_lister_reply(reply)
      v1 = reply.include?("[BEGIN_diDATA]")
      data = v1 || reply.include?("[Data]")
      entries = []
      more = nil
      in_rows = !v1
      reply.each do |line|
        in_rows = true if line == "[BEGIN_diDATA]"
        in_rows = false if v1 && lister_v1_data_closed?(line)
        next if line.start_with?("[") # section markers, including [END_diDATA]
        if line.start_with?("MORE^")
          pieces = line.split("^", -1)
          more = { value: pieces[1], ien: pieces[2] }
          next
        end
        next unless in_rows

        pieces = line.split("^", -1)
        entries << { ien: pieces[0], pieces: pieces[1..] }
      end
      error = reply.include?("[Errors]") || reply.include?("[BEGIN_diERRORS]")
      unless data
        entries = []
        error = true if reply.any? { |line| !line.start_with?("[") && !line.start_with?("MORE^") }
      end
      { entries: entries, more: more, error: error, data: data }
    end

    # "[END_diDATA]" ends the V1 row list. An error marker does too, so
    # the text under it is not parsed as another row.
    def lister_v1_data_closed?(line)
      line == "[END_diDATA]" || line == "[BEGIN_diERRORS]" ||
        line == "[Errors]" || line == "[END_diERRORS]"
    end

    # Normalize a broker reply to an array of lines: MockClient returns an
    # Array (or a single-line String); a live broker returns a CR+LF-joined
    # stream. nil/empty → nil (no response at all).
    def lines(response)
      return nil if response.nil?
      list = response.is_a?(Array) ? response.map(&:to_s) : response.to_s.split(/\r?\n/)
      list.empty? ? nil : list
    end

    # Extract the human-readable DIERR TEXT lines from a
    # [BEGIN_diERRORS]..[END_diERRORS] block (ERROR^DDR3: DDR3.m:63-79 —
    # per error: a caret-delimited header, caret-delimited PARAM rows, then
    # plain text lines). Lines without "^" inside the block are the text;
    # if none parse that way the whole block is returned verbatim.
    def error_block(reply)
      from = reply.index("[BEGIN_diERRORS]")
      return [] unless from
      to = reply.index("[END_diERRORS]") || reply.length
      block = reply[(from + 1)...to]
      texts = block.reject { |l| l.include?("^") }
      texts.empty? ? block : texts
    end
  end
end
