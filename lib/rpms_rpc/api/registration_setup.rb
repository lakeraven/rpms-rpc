# frozen_string_literal: true

require_relative "../shape"
require_relative "../context_scope"
require_relative "../fileman_date_parser"
require_relative "ddr_fileman"

module RpmsRpc
  # Two registration tables a site keeps itself, which BPRM edits under
  # Settings > Table Maintenance and no stock RPC files: the eligibility
  # modifiers a clerk picks as proof of a legal name, a legal document or legal
  # sex, and the site's own (Category II) patient record flags. Reads use DDR
  # LISTER and DDR GETS ENTRY DATA, writes DDR FILER, under CIAV VUECENTRIC,
  # the way SchedulingSetup and WaitList do.
  #
  # ELIGIBILITY MODIFIERS (#9000030). One table holds two kinds of entry, told
  # apart by .02 TYPE, a free-text code its input transform limits to a run of
  # "ICDP" (the reasons behind an eligibility status) or up to four of A, L, N
  # and S: N proof of a name change (LEGAL NAMES #9000033 .04 PROOF PROVIDED),
  # L a legal document (PATIENTS LEGAL DOCS #9000034 .03), A an advance
  # directive, S proof of legal sex (#9000001.9201 field 2 SOURCE). BPRM's
  # Eligibility Modifiers page (EligibilityModifierForm.razor) adds an entry
  # with an upper-case description and one of the types N, L, S, NL, NS, LS or
  # NLS, and edits only the description of an existing one; its key is AGZMGR
  # (CanAccessRegistrationTableMaintenance). This module adds and renames only
  # those N/L/S entries: an eligibility-status reason (I, C, D, P) or an
  # advance-directive type (A) is read, never written here.
  #
  # PRF LOCAL FLAG (#26.11) and PRF LOCAL FLAG HISTORY (#26.12). DGPF's own
  # editor (DGPFLF4, DGPFLF5) files a flag and a history entry together with
  # $$STOALL^DGPFALF1, and no #8994 entry reaches it; BPRM
  # (PrfLocalFlagRepository) inserts or updates the flag, then inserts the
  # history entry (.01 the flag, .02 now, .03 the user) and its .04 EDIT
  # REASON, "New Local Patient Record Flag entered." for a new flag. This
  # module files the same with DDR FILER, in that order. What DGPF checks
  # and DDR FILER does not, this module checks first: a name is not already a
  # flag (FNDFLAG^DGPFALF), and notification days are not more than review
  # frequency days and are 0 when the review frequency is 0 (DGPFLF5). Like
  # BPRM, it files no .06 REVIEW MAIL GROUP or .07 TIU PN TITLE. When the
  # history entry fails after a new flag was filed, the new flag is deleted, as
  # STOALL rolls back. A flag is never deleted otherwise: STATUS 0 inactivates
  # it, and its assignments (#26.13) are left alone.
  #
  # Word processing (a flag's DESCRIPTION, a history entry's EDIT REASON) is
  # filed in EDIT mode with the value "DDRIENS" and the lines in that
  # parameter, as WaitList.set_comments does (rpms-rpc#641).
  module RegistrationSetup
    extend self
    extend Shape::Declarable

    CONTEXT = "CIAV VUECENTRIC"

    MODIFIER_FILE = "9000030"
    # BPRM's choices for a new entry's TYPE, in its order.
    LEGAL_DOCUMENT_TYPES = %w[N L S NL NS LS NLS].freeze
    MODIFIER_NAME = (3..80)

    FLAG_FILE = "26.11"
    HISTORY_FILE = "26.12"
    TYPE_FILE = "26.16"
    FLAG_FIELDS = "@;.01;.02I;.03I;.03E;.04;.05"
    DESCRIPTION_FIELD = "1"
    REASON_FIELD = ".04"
    REVIEW_DAYS = (0..9999)
    NOTIFICATION_DAYS = (0..9998)
    NEW_FLAG_REASON = "New Local Patient Record Flag entered."

    # How many entries one DDR LISTER call asks for; a longer list is read on
    # from the MORE marker.
    PAGE = 100

    # Every ELIGIBILITY MODIFIERS (#9000030) entry, by name:
    # [{ ien:, name:, type:, legal_document: }], legal_document true when the
    # type is made only of N, L and S (an entry this module may rename). A
    # failed read raises Client::RpcError.
    def eligibility_modifier_table
      list(MODIFIER_FILE, "@;.01;.02").map do |entry|
        name, type = entry[:pieces]
        { ien: entry[:ien].to_i, name: name.to_s, type: type.to_s, legal_document: legal_document_type?(type.to_s) }
      end.sort_by { |row| [ row[:name], row[:ien] ] }
    end
    shape :eligibility_modifier_table, resource: "registration-setups", verb: "GET",
          path: "/registration-setups/eligibility-modifier-table"

    # Add a legal-document modifier: name (3 to 80 characters, filed upper
    # case, not starting with punctuation) and type, one of
    # LEGAL_DOCUMENT_TYPES. Refused with nothing filed otherwise. Returns
    # { success: true, ien: }, a failure hash, or nil when DDR FILER gives no
    # reply.
    def add_eligibility_modifier(name:, type:)
      text = modifier_name(name)
      return invalid("a name of #{MODIFIER_NAME.min} to #{MODIFIER_NAME.max} characters, not starting with punctuation, is required") unless text
      return invalid("type: takes one of #{LEGAL_DOCUMENT_TYPES.join(', ')}") unless LEGAL_DOCUMENT_TYPES.include?(type)

      in_context do
        rows = [ row(MODIFIER_FILE, ".01", "+1,", text), row(MODIFIER_FILE, ".02", "+1,", type) ]
        added(DdrFileman.filer(mode: "ADD", rows: rows))
      end
    end
    shape :add_eligibility_modifier, resource: "registration-setups", verb: "POST",
          path: "/registration-setups/eligibility-modifier"

    # Rename a legal-document modifier. Its type is left as it is, as BPRM
    # does. :not_found when there is no such entry, :invalid when it is an
    # eligibility-status reason or an advance-directive type. Returns
    # { success: true }, a failure hash, or nil when DDR FILER gives no reply.
    def rename_eligibility_modifier(ien, name:)
      text = modifier_name(name)
      return invalid("a name of #{MODIFIER_NAME.min} to #{MODIFIER_NAME.max} characters, not starting with punctuation, is required") unless text

      in_context do
        current = eligibility_modifier_table.find { |entry| entry[:ien] == ien.to_i }
        next not_found("no such eligibility modifier") unless current
        next invalid("only a name change, legal document or legal sex modifier is changed here") unless current[:legal_document]

        outcome(DdrFileman.filer(mode: "EDIT", rows: [ row(MODIFIER_FILE, ".01", "#{ien.to_i},", text) ]))
      end
    end
    shape :rename_eligibility_modifier, resource: "registration-setups", verb: "POST",
          path: "/registration-setups/{ien}/rename-eligibility-modifier"

    # The PRF TYPE (#26.16) entries a flag can carry: [{ ien:, name: }], by
    # name. A failed read raises Client::RpcError.
    def flag_types
      list(TYPE_FILE, "@;.01").map { |entry| { ien: entry[:ien].to_i, name: entry[:pieces][0].to_s } }
                              .sort_by { |row| row[:name] }
    end
    shape :flag_types, resource: "registration-setups", verb: "GET",
          path: "/registration-setups/flag-types"

    # Every PRF LOCAL FLAG (#26.11), by name:
    # [{ ien:, name:, active:, type_ien:, type:, review_days:, notification_days: }].
    # A failed read raises Client::RpcError.
    def local_flags
      list(FLAG_FILE, FLAG_FIELDS).map { |entry| flag_row(entry) }.sort_by { |row| [ row[:name], row[:ien] ] }
    end
    shape :local_flags, resource: "registration-setups", verb: "GET",
          path: "/registration-setups/local-flags"

    # One flag as local_flags lists it, with description: its DESCRIPTION
    # lines ([] when none). nil when there is no such flag. A failed read
    # raises Client::RpcError.
    def local_flag(ien)
      found = local_flags.find { |row| row[:ien] == ien.to_i }
      found && found.merge(description: word_processing(FLAG_FILE, "#{ien.to_i},", DESCRIPTION_FIELD))
    end
    shape :local_flag, resource: "registration-setups", verb: "GET",
          path: "/registration-setups/{ien}/local-flag"

    # A flag's PRF LOCAL FLAG HISTORY (#26.12) entries, oldest first:
    # [{ ien:, edited_at: Time, edited_by: DUZ, reason: [lines] }]. A failed
    # read raises Client::RpcError.
    def local_flag_history(ien)
      screen = "I $P(^(0),U,1)=#{ien.to_i}"
      entries = list(HISTORY_FILE, "@;.02I;.03I", screen: screen)
      entries.map do |entry|
        edited_at, edited_by = entry[:pieces]
        { ien: entry[:ien].to_i, edited_at: FilemanDateParser.parse_datetime(edited_at),
          edited_by: id_or_nil(edited_by), reason: word_processing(HISTORY_FILE, "#{entry[:ien]},", REASON_FIELD) }
      end.sort_by { |row| row[:ien] }
    end
    shape :local_flag_history, resource: "registration-setups", verb: "GET",
          path: "/registration-setups/{ien}/local-flag-history"

    # Add a local flag: name (3 to 30 characters, filed upper case: letters,
    # digits and spaces, starting with a letter), type (a #26.16 IEN),
    # review_days (0 to 9999), notification_days (0 to 9998, not more than
    # review_days, 0 when review_days is 0), description (lines, optional) and
    # active. Files the flag, then its history entry with NEW_FLAG_REASON.
    # Returns { success: true, ien: }, a failure hash, or nil when DDR FILER
    # gives no reply.
    def add_local_flag(name:, type:, review_days:, notification_days:, description: [], active: true)
      text = flag_name(name)
      return invalid("a name of 3 to 30 letters, digits and spaces, starting with a letter, is required") unless text

      refused = refuse_flag(type, review_days, notification_days, description)
      return refused if refused

      in_context do
        next invalid("is already a local flag") if local_flags.any? { |row| row[:name] == text }
        next invalid("is not a flag type") unless flag_types.any? { |row| row[:ien] == type }

        duz = signed_on_duz
        next invalid("a signed-on DUZ is required") unless duz

        filed = added(DdrFileman.filer(mode: "ADD", rows: flag_rows("+1,", text, type, review_days, notification_days, active)))
        next filed unless filed.is_a?(Hash) && filed[:success]

        ien = filed[:ien]
        written = file_description(ien, description, clear: false)
        written = record_history(ien, duz, [ NEW_FLAG_REASON ]) if written.is_a?(Hash) && written[:success]
        next filed if written.is_a?(Hash) && written[:success]

        rolled = outcome(DdrFileman.filer(mode: "EDIT", rows: [ row(FLAG_FILE, ".01", "#{ien},", "@") ]))
        partial("the flag was not kept: its history entry could not be filed (#{written ? written[:message] : 'no reply'})" \
                "#{rolled&.dig(:success) ? '' : '; deleting the half-filed flag failed too'}")
      end
    end
    shape :add_local_flag, resource: "registration-setups", verb: "POST",
          path: "/registration-setups/local-flag"

    # Change a local flag: every value add_local_flag takes, plus reason (the
    # edit reason, lines, required, as DGPF and BPRM require it). active: false
    # inactivates the flag. Files the flag, then a history entry with reason.
    # :not_found when there is no such flag. Returns { success: true }, a
    # failure hash, or nil when DDR FILER gives no reply. When the flag was
    # filed and its history was not, { success: false, error: :partial }.
    def update_local_flag(ien, name:, type:, review_days:, notification_days:, active:, reason:, description: [])
      text = flag_name(name)
      return invalid("a name of 3 to 30 letters, digits and spaces, starting with a letter, is required") unless text

      refused = refuse_flag(type, review_days, notification_days, description) || refuse_lines(reason, "reason", required: true)
      return refused if refused

      in_context do
        next not_found("no such local flag") unless local_flags.any? { |row| row[:ien] == ien.to_i }
        next invalid("is already a local flag") if local_flags.any? { |row| row[:name] == text && row[:ien] != ien.to_i }
        next invalid("is not a flag type") unless flag_types.any? { |row| row[:ien] == type }

        duz = signed_on_duz
        next invalid("a signed-on DUZ is required") unless duz

        filed = outcome(DdrFileman.filer(mode: "EDIT", rows: flag_rows("#{ien.to_i},", text, type, review_days, notification_days, active)))
        next filed unless filed.is_a?(Hash) && filed[:success]

        written = file_description(ien.to_i, description, clear: true)
        written = record_history(ien.to_i, duz, reason) if written.is_a?(Hash) && written[:success]
        next filed if written.is_a?(Hash) && written[:success]

        partial("the flag was changed, but its history entry was not filed (#{written ? written[:message] : 'no reply'})")
      end
    end
    shape :update_local_flag, resource: "registration-setups", verb: "PUT",
          path: "/registration-setups/{ien}/local-flag"

    private

    def legal_document_type?(type) = type.match?(/\A[NLS]+\z/)

    def modifier_name(name)
      text = name.to_s.strip.upcase
      return nil unless MODIFIER_NAME.cover?(text.length)
      return nil if text.match?(/\A[[:punct:]]/) || text.match?(/[\^[:cntrl:]]/)

      text
    end

    # The .01 input transform of #26.11: upper case, 3 to 30 characters, a
    # letter first, no punctuation, and no trailing space.
    def flag_name(name)
      text = name.to_s.strip.upcase
      text.match?(/\A[A-Z][A-Z0-9 ]{2,29}\z/) ? text : nil
    end

    def refuse_flag(type, review_days, notification_days, description)
      return invalid("type: takes a flag type's IEN") unless type.is_a?(Integer) && type.positive?
      return invalid("review frequency days must be a whole number from 0 to 9999") unless review_days.is_a?(Integer) && REVIEW_DAYS.cover?(review_days)
      unless notification_days.is_a?(Integer) && NOTIFICATION_DAYS.cover?(notification_days)
        return invalid("notification days must be a whole number from 0 to 9998")
      end
      return invalid("notification days cannot be more than review frequency days") if notification_days > review_days

      refuse_lines(description, "description", required: false)
    end

    def refuse_lines(lines, what, required:)
      return invalid("#{what}: takes an Array of Strings") unless lines.is_a?(Array) && lines.all?(String)
      return invalid("#{what} is required") if required && lines.none? { |line| !line.strip.empty? }
      return invalid("a #{what} line cannot hold a line break") if lines.any? { |line| line.match?(/[\r\n]/) }
      # GETSC^DDR2 ends a word-processing block at a line "$$END$$".
      return invalid("a #{what} line cannot be #{WP_END}") if lines.include?(WP_END)

      nil
    end

    def flag_rows(iens, name, type, review_days, notification_days, active)
      [ row(FLAG_FILE, ".01", iens, name), row(FLAG_FILE, ".02", iens, active ? "1" : "0"),
        row(FLAG_FILE, ".03", iens, type), row(FLAG_FILE, ".04", iens, review_days),
        row(FLAG_FILE, ".05", iens, notification_days) ]
    end

    def file_description(ien, lines, clear:)
      text = lines.reject { |line| line.strip.empty? }
      return { success: true } if text.empty? && !clear

      value = text.empty? ? "@" : WP_VALUE
      iens = text.each_with_index.to_h { |line, i| [ i + 1, line ] }
      outcome(DdrFileman.filer(mode: "EDIT", rows: [ row(FLAG_FILE, DESCRIPTION_FIELD, "#{ien},", value) ], iens: iens))
    end

    def record_history(ien, duz, reason)
      now = canonical(FilemanDateParser.to_fileman(Time.now))
      rows = [ row(HISTORY_FILE, ".01", "+1,", ien), row(HISTORY_FILE, ".02", "+1,", now), row(HISTORY_FILE, ".03", "+1,", duz) ]
      filed = added(DdrFileman.filer(mode: "ADD", rows: rows))
      return filed unless filed.is_a?(Hash) && filed[:success]

      lines = reason.reject { |line| line.strip.empty? }.each_with_index.to_h { |line, i| [ i + 1, line ] }
      outcome(DdrFileman.filer(mode: "EDIT", rows: [ row(HISTORY_FILE, REASON_FIELD, "#{filed[:ien]},", WP_VALUE) ], iens: lines))
    end

    def flag_row(entry)
      name, status, type_ien, type, review, notification = entry[:pieces]
      { ien: entry[:ien].to_i, name: name.to_s, active: status == "1", type_ien: id_or_nil(type_ien), type: type.to_s,
        review_days: review.to_s.empty? ? nil : review.to_i, notification_days: notification.to_s.empty? ? nil : notification.to_i }
    end

    def word_processing(file, iens, field)
      reply = in_context { DdrFileman.gets_entry(file: file, iens: iens, fields: field, flags: "E") }
      raise Client::RpcError, "DDR GETS gave no reply for ##{file} #{iens}" if reply.nil?
      raise Client::RpcError, "DDR GETS refused ##{file} #{iens}" if reply[:error] || reply[:malformed]

      Array(reply.dig(:fields, field, :text))
    end

    def list(file, fields, screen: nil)
      out = []
      from = nil
      loop do
        page = in_context { DdrFileman.lister(file: file, fields: fields, flags: "IP", max: PAGE, from: from, screen: screen) }
        raise Client::RpcError, "DDR LISTER gave no reply for ##{file}" if page.nil?
        raise Client::RpcError, "DDR LISTER refused ##{file}" if page[:error]

        out.concat(page[:entries])
        return out unless page[:more]

        from = page[:more][:value]
      end
    end

    WP_VALUE = "DDRIENS"
    WP_END = "$$END$$"
    private_constant :WP_VALUE, :WP_END

    def row(file, field, iens, value) = { file: file, field: field, iens: iens, value: value.to_s }

    def id_or_nil(text) = text.to_s.match?(/\A[1-9]\d*\z/) ? text.to_i : nil

    # A FileMan date/time with no trailing zeros, as $$NOW^XLFDT gives it:
    # "3261112.13354" for 13:35:40, so the C cross-reference subscript is the
    # number and not the string "3261112.133540".
    def canonical(value) = value.include?(".") ? value.sub(/0+\z/, "").chomp(".") : value

    def added(filed)
      return nil if filed.nil?

      filed[:success] ? { success: true, ien: filed[:iens][1].to_i } : failed(filed)
    end

    def outcome(filed)
      return nil if filed.nil?

      filed[:success] ? { success: true } : failed(filed)
    end

    def failed(filed) = { success: false, error: :filer_failed, message: Array(filed[:errors]).join("\n") }

    def signed_on_duz
      client = RpmsRpc.client
      return nil unless client.respond_to?(:duz)

      text = client.duz.to_s
      text.match?(/\A[1-9]\d*\z/) ? text : nil
    end

    def in_context(&) = ContextScope.scoped(RpmsRpc.client, CONTEXT, &)
    def invalid(message) = { success: false, error: :invalid, message: message }
    def not_found(message) = { success: false, error: :not_found, message: message }
    def partial(message) = { success: false, error: :partial, message: message }
  end
end
