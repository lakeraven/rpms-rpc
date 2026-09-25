# frozen_string_literal: true

require_relative "../mappings"

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
    def filer(mode:, rows:, iens: {}, flags: "")
      reply = lines(call(:ddr_filer, *filer_params(mode: mode, rows: rows, iens: iens, flags: flags)))
      return nil if reply.nil?

      resolved = reply.filter_map { |l| l.match(/\A\+(\d+),\^(.*)\z/) }
                      .to_h { |md| [ md[1].to_i, md[2] ] }
      errors = error_block(reply)
      { success: errors.empty?, iens: resolved, errors: errors }
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
    # error: bool } or nil (no response). Reply grammar is the V0 shape —
    # over the CIA broker XWBAPVER is unset (ACTR^CIANBACT reads it from
    # the frame's VER field, CIANBACT.m:67, which RPC frames don't carry):
    # optional "[Misc]" + "MORE^from^ien", "[Data]" + packed IEN-first rows,
    # "[Errors]" marker (V0^DDR: DDR.m:21-30,45). NB: the exact packed-row
    # column set rides LIST^DIC's "P" output; parse row pieces defensively.
    def lister(file:, iens: nil, fields: nil, flags: nil, max: nil, from: nil,
               part: nil, xref: nil, screen: nil, id: nil, options: nil)
      param = lister_param(file: file, iens: iens, fields: fields, flags: flags, max: max,
                           from: from, part: part, xref: xref, screen: screen, id: id,
                           options: options)
      reply = lines(call(:ddr_lister, param))
      return nil if reply.nil?

      entries = []
      more = nil
      reply.each do |line|
        next if line.start_with?("[") # section markers
        if line.start_with?("MORE^")
          pieces = line.split("^", -1)
          more = { value: pieces[1], ien: pieces[2] }
        else
          pieces = line.split("^", -1)
          entries << { ien: pieces[0], pieces: pieces[1..] }
        end
      end
      error = reply.any? { |l| l == "[Errors]" || l == "[BEGIN_diERRORS]" }
      { entries: entries, more: more, error: error }
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
    # `timeout` seconds; false on timeout or no broker response.
    def lock(node:, timeout: 5)
      DataMapper.ddr_lock_unlock_node.fetch_scalar(lock_param(node: node, timeout: timeout)) == true
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

    # Read field values via GETS^DIQ. Default (no OPTIONS) reply format:
    # "[Data]" then "FILE^IEN^FIELD^INTERNAL^EXTERNAL" rows (word-processing
    # fields become "...^[WORD PROCESSING]" + text + "$$END$$"), "[ERROR]"
    # marker when DDRERR is set (GETSC^DDR2 + tags 1/2: DDR2.m:22-43,61).
    #
    # Returns { fields: { "FIELD#" => {internal:, external:} }, error: bool }
    # or nil (no response). Word-processing fields yield {text: [lines]}.
    # A reply that parses NO field rows and carries no "[Data]" marker is
    # reported as an error: broker/M error strings ("-1^...", raw error
    # text) don't match the FILE^IENS^FIELD^... grammar, and silently
    # returning empty fields would let callers fabricate "value absent"
    # from "read failed".
    def gets_entry(file:, iens:, fields:, flags: "")
      reply = lines(call(:ddr_gets_entry_data,
        gets_entry_param(file: file, iens: iens, fields: fields, flags: flags)))
      return nil if reply.nil?

      result = {}
      wp_field = nil
      reply.each do |line|
        if wp_field
          if line == "$$END$$"
            wp_field = nil
          else
            result[wp_field][:text] << line
          end
          next
        end
        next if line.start_with?("[") # [Data] / [ERROR] markers
        pieces = line.split("^", -1)
        next if pieces.length < 4
        field = pieces[2]
        if pieces[3] == "[WORD PROCESSING]"
          result[field] = { text: [] }
          wp_field = field
        else
          result[field] = { internal: pieces[3], external: pieces[4..].join("^") }
        end
      end
      error = reply.include?("[ERROR]") ||
              (result.empty? && !reply.include?("[Data]"))
      { fields: result, error: error }
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

    private

    def call(mapping_name, *params)
      RpmsRpc.client.call_rpc(DataMapper[mapping_name].rpc_name, *params)
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
