# frozen_string_literal: true

require "date"
require_relative "../server_clock"
require_relative "../fileman_date_parser"

module RpmsRpc
  # A patient's advance directives (rpms-ux S-REG-17): whether they have one,
  # of what type, from when, or why they have none. They are kept in ADVANCE
  # DIRECTIVE (#9000040), one entry per patient DINUM'd to the DFN, in its
  # DATE OF ENTRY multiple (#9000040.11):
  #
  #   .01 DATE OF ENTRY       date
  #   .02 ADVANCE DIRECTIVE   set, Y:YES N:NO
  #   .03 TYPE                pointer to ELIGIBILITY MODIFIERS (#9000030),
  #                           screened to entries whose .02 TYPE holds "A"
  #                           (LIVING WILL, POWER OF ATTORNEY on the demo file)
  #   .04 REASON              free text, 3 to 30 characters, why there is none
  #
  # No stock RPC files them for a registration user. AG's GUI window
  # "Advance Directives" (#9009068.3 entry 22) is display-only: it names no
  # save RPC and no REASON parameter, so AGG UPDATE A MULTIPLE RECORD cannot
  # add to it. AG's roll-and-scroll edits the multiple with ^DIE (ADVDIRED^AGED11A),
  # and BPRM writes the BMW tables over SQL (AdvanceDirectiveRepository). So
  # they are read with DDR LISTER and filed with DDR FILER, under the rules of
  # rpms-rpc#549, as the eligibility modifiers are: inside AG's edit lock
  # (Agg.editing), read before write, and AG's page stamp (UPDATE1^AGED) in
  # the same call.
  #
  # What AG's and BPRM's screens check, and so what this module checks before
  # it files anything (BPRM's ChangeAdvanceDirectiveCommandValidator and its
  # async validator; AG's DR string in EDADVDIR^AGED11A):
  # - a date of entry is required;
  # - a directive needs a type, and keeps no reason; no directive needs a
  #   reason of 3 to 30 characters, and keeps no type;
  # - a directive of the same type on the same date is refused.
  #
  # AG*7.1*17 adds registration warning 55, "Advance Directives missing"
  # (WADD^AGEDERR4): it fires for an active, living patient with no entry in
  # the multiple at all, whatever the answer. Recording either answer clears
  # it; removing the last entry brings it back.
  module Registration
    ADVANCE_DIRECTIVE_FILE = "9000040"
    ADVANCE_DIRECTIVE_ENTRY_FILE = "9000040.11"
    ADVANCE_DIRECTIVE_FIELDS = "@;.01I;.02I;.03I;.03E;.04"
    ADVANCE_DIRECTIVE_TYPE_SCREEN = "I $P(^(0),U,2)[\"A\""
    ADVANCE_DIRECTIVE_REASON = (3..30)

    # The types a directive can have: [{ ien:, name: }] from #9000030, as the
    # TYPE field screens them. Raises Client::RpcError on a failed read.
    def advance_directive_types
      in_context { choice_list(ELIGIBILITY_MODIFIER_FILE, ADVANCE_DIRECTIVE_TYPE_SCREEN) }
    end
    shape :advance_directive_types, resource: "registrations", verb: "GET",
          path: "/registrations/advance-directive-types"

    # The patient's advance directive entries, newest first:
    #   [{ ien:, entered_on: Date, directive: true/false, type_ien:, type:,
    #      reason: }]
    # type_ien and type are nil without a type, reason nil without a reason.
    # [] when nothing is on file. Raises Client::RpcError on a failed read,
    # so a failed read is never "none on file".
    def advance_directives(dfn)
      id = patient_dfn(dfn)
      raise ArgumentError, "a positive DFN is required" unless id

      in_context { advance_directive_rows(id) }
    end
    shape :advance_directives, resource: "registrations", verb: "GET",
          path: "/patients/{dfn}/registrations/advance-directives"

    # Record an answer (S-REG-17.1, 17.2): directive true with a type (a
    # #9000030 IEN from advance_directive_types), or false with a reason.
    # entered_on is a Date, default the server's today. A first answer also
    # creates the patient's #9000040 entry.
    #
    # Refused with nothing filed (:invalid): a directive with no type or with
    # a reason, no directive with no reason or with a type, a reason that is
    # not 3 to 30 characters, a type that is not an advance-directive type,
    # and a directive of the same type already on file for that date. Returns
    # { success: true }, :filer_failed, or nil when DDR FILER gives no reply.
    def record_advance_directive(dfn, directive:, type: nil, reason: nil, entered_on: nil)
      id = patient_dfn(dfn)
      return invalid("a positive DFN is required") unless id

      answer = advance_directive_answer(directive, type, reason, entered_on)
      return answer if answer.key?(:success)

      Agg.editing(dfn: id) { in_context { write_advance_directive(id, nil, answer) } }
    end
    shape :record_advance_directive, resource: "registrations", verb: "POST",
          path: "/patients/{dfn}/registrations/advance-directive"

    # Change one entry (S-REG-17.6): its date, answer, type and reason are
    # replaced as given, and the field the answer does not keep is cleared, as
    # AG's page and BPRM's form do. Checked as record_advance_directive, with
    # the entry itself left out of the same-type check; :not_found when the
    # patient has no such entry.
    def change_advance_directive(dfn, ien, directive:, type: nil, reason: nil, entered_on: nil)
      id = patient_dfn(dfn)
      return invalid("a positive DFN is required") unless id
      return invalid("an entry number is required") unless positive_integer?(ien)

      answer = advance_directive_answer(directive, type, reason, entered_on)
      return answer if answer.key?(:success)

      Agg.editing(dfn: id) { in_context { write_advance_directive(id, ien, answer) } }
    end
    shape :change_advance_directive, resource: "registrations", verb: "PUT",
          path: "/patients/{dfn}/registrations/{ien}/advance-directive"

    # Remove one entry entered in error (S-REG-17.5). :not_found when the
    # patient has no such entry. The #9000040 entry itself is kept.
    def remove_advance_directive(dfn, ien)
      id = patient_dfn(dfn)
      return invalid("a positive DFN is required") unless id
      return invalid("an entry number is required") unless positive_integer?(ien)

      Agg.editing(dfn: id) do
        in_context do
          next not_found("no such advance directive on file") unless advance_directive_rows(id).any? { |row| row[:ien] == ien }

          stamp = update1_stamp_rows(id)
          next stamp if stamp.is_a?(Hash)

          rows = [ edit_row(ADVANCE_DIRECTIVE_ENTRY_FILE, ".01", "#{ien},#{id},", "@") ]
          filer_outcome(DdrFileman.filer(mode: "ADD", rows: rows + stamp))
        end
      end
    end
    shape :remove_advance_directive, resource: "registrations", verb: "DELETE",
          path: "/patients/{dfn}/registrations/{ien}/advance-directive"

    private

    # The answer checked before anything is sent: { directive:, type:,
    # reason:, entered_on: } (entered_on nil means the server's today), or an
    # :invalid failure hash.
    def advance_directive_answer(directive, type, reason, entered_on)
      return invalid("directive: takes true or false") unless [ true, false ].include?(directive)
      return invalid("entered_on: takes a Date") unless entered_on.nil? || entered_on.instance_of?(Date)

      text = reason.to_s.strip
      if directive
        return invalid("Type is required for an advance directive") unless positive_integer?(type)
        return invalid("Reason is kept only when there is no advance directive") unless text.empty?
      else
        return invalid("Type is kept only for an advance directive") unless type.nil?
        return invalid("Reason is required when there is no advance directive") if text.empty?
        unless ADVANCE_DIRECTIVE_REASON.cover?(text.length)
          return invalid("Reason must be #{ADVANCE_DIRECTIVE_REASON.min} to #{ADVANCE_DIRECTIVE_REASON.max} characters")
        end
      end

      { directive: directive, type: type, reason: (directive ? nil : text), entered_on: entered_on }
    end

    def advance_directive_rows(id)
      read = DdrFileman.gets_entry(file: ADVANCE_DIRECTIVE_FILE, iens: "#{id},", fields: ".01", flags: "I")
      raise Client::RpcError, "DDR GETS ENTRY DATA gave no reply for ##{ADVANCE_DIRECTIVE_FILE}" if read.nil?
      return [] if read[:error] # no #9000040 entry: nothing on file yet

      listed = DdrFileman.lister(file: ADVANCE_DIRECTIVE_ENTRY_FILE, iens: ",#{id},", fields: ADVANCE_DIRECTIVE_FIELDS,
                                 flags: "IP")
      raise Client::RpcError, "DDR LISTER gave no reply for ##{ADVANCE_DIRECTIVE_ENTRY_FILE}" if listed.nil?
      raise Client::RpcError, "DDR LISTER refused ##{ADVANCE_DIRECTIVE_ENTRY_FILE}" if listed[:error] || listed[:more]

      listed[:entries].map { |entry| advance_directive_row(entry) }.sort_by { |row| [ row[:entered_on], row[:ien] ] }.reverse
    end

    def advance_directive_row(entry)
      date, answer, type_ien, type, reason = entry[:pieces]
      entered_on = FilemanDateParser.parse_date(date)
      raise Client::RpcError, "DDR LISTER returned an advance directive with an unreadable date of entry" unless entered_on

      { ien: entry[:ien].to_i, entered_on: entered_on, directive: answer.to_s == "Y",
        type_ien: type_ien.to_s.empty? ? nil : type_ien.to_i, type: type.to_s.empty? ? nil : type.to_s,
        reason: reason.to_s.empty? ? nil : reason.to_s }
    end

    # Inside the lock: read, check, then one DDR FILER call with the entry
    # and AG's page stamp. ien nil adds a new entry.
    def write_advance_directive(id, ien, answer)
      current = advance_directive_rows(id)
      return not_found("no such advance directive on file") if ien && current.none? { |row| row[:ien] == ien }

      if answer[:directive]
        unless advance_directive_types.any? { |row| row[:ien] == answer[:type] }
          return invalid("Type is not an advance directive type")
        end
      end

      entered_on = answer[:entered_on] || ServerClock.today
      if answer[:directive] && current.any? do |row|
        row[:ien] != ien && row[:directive] && row[:type_ien] == answer[:type] && row[:entered_on] == entered_on
      end
        return invalid("an advance directive of this type is already on file for that date")
      end

      stamp = update1_stamp_rows(id)
      return stamp if stamp.is_a?(Hash)

      rows, pins = advance_directive_filer_rows(id, ien, answer, entered_on, top_exists: !current.empty? || advance_directive_top?(id))
      filer_outcome(DdrFileman.filer(mode: "ADD", rows: rows + stamp, iens: pins))
    end

    def advance_directive_top?(id)
      read = DdrFileman.gets_entry(file: ADVANCE_DIRECTIVE_FILE, iens: "#{id},", fields: ".01", flags: "I")
      raise Client::RpcError, "DDR GETS ENTRY DATA gave no reply for ##{ADVANCE_DIRECTIVE_FILE}" if read.nil?

      !read[:error]
    end

    # The rows for one entry. A new entry is "+2," under the patient's
    # #9000040 entry, which is added first as "+1," pinned to the DFN (the
    # .01 is DINUM'd) when the patient has none yet. An edit sends "@" for
    # the field its answer does not keep.
    def advance_directive_filer_rows(id, ien, answer, entered_on, top_exists:)
      rows = []
      pins = {}
      if ien
        node = "#{ien},#{id},"
      else
        unless top_exists
          rows << edit_row(ADVANCE_DIRECTIVE_FILE, ".01", "+1,", id)
          pins[1] = id.to_i
        end
        node = top_exists ? "+2,#{id}," : "+2,+1,"
      end

      rows << edit_row(ADVANCE_DIRECTIVE_ENTRY_FILE, ".01", node, FilemanDateParser.to_fileman(entered_on))
      rows << edit_row(ADVANCE_DIRECTIVE_ENTRY_FILE, ".02", node, answer[:directive] ? "Y" : "N")
      if answer[:directive]
        rows << edit_row(ADVANCE_DIRECTIVE_ENTRY_FILE, ".03", node, answer[:type].to_s)
        rows << edit_row(ADVANCE_DIRECTIVE_ENTRY_FILE, ".04", node, "@") if ien
      else
        rows << edit_row(ADVANCE_DIRECTIVE_ENTRY_FILE, ".04", node, answer[:reason])
        rows << edit_row(ADVANCE_DIRECTIVE_ENTRY_FILE, ".03", node, "@") if ien
      end
      [ rows, pins ]
    end
  end
end
