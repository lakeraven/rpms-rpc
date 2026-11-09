# frozen_string_literal: true

require "date"
require_relative "../shape"
require_relative "../context_scope"
require_relative "../fileman_date_parser"
require_relative "ddr_fileman"

module RpmsRpc
  # A clinic's wait list (rpms-ux S-SCH-10): WAITING LIST (#9009017.1,
  # ^BSDWL), one entry per clinic, each with its patients (#9009017.11), each
  # patient's reason and resolution from WAITING LIST REASON (#9009017.4,
  # ^BSDWLR).
  #
  # Stock edits these only in roll-and-scroll (BSDWLE: ADD, EDIT, REMOVE
  # protocols of BSDAM WAITING LIST), and the one #8994 entry, BSDX WAITLIST,
  # only reads the open list of an active clinic. So this module reads with
  # DDR LISTER and files with DDR FILER, under the rules of rpms-rpc#549: read
  # before write (a failed read files nothing), what the screens do around
  # the write done explicitly, and a live spec that reads every write back
  # through FileMan. What BSDWLE does, from the FOIA source:
  # - An inactive list takes no one (BSDWLE: "Wait List is Inactive").
  # - .04 USER WHO ADDED and .11 USER WHO REMOVED are the signed-on user.
  # - .09 REASON ADDED and .08 RESOLUTION screen on the reason's .02 TYPE and
  #   .03 INACTIVE (their DIC("S")), which DDR FILER does not run, so the
  #   module checks them.
  # - An entry is closed by .07 DATE REMOVED FROM LIST.
  #
  # COMMENTS (field 1, the word-processing subfile #9009017.111) is read with
  # DDR GETS ENTRY DATA and filed with DDR FILER (rpms-rpc#641, rpms-ops#1083).
  # A FileMan word-processing value is the name of an array, and FILEC^DDR3
  # holds one in scope in EDIT mode: its fourth parameter, DDRIENS, otherwise
  # unused there. So the field's value is the text "DDRIENS" and the lines go
  # in that parameter. A filing replaces the whole field.
  module WaitList
    extend self
    extend Shape::Declarable

    CONTEXT = "CIAV VUECENTRIC"

    LIST_FILE = "9009017.1"
    ENTRY_FILE = "9009017.11"
    REASON_FILE = "9009017.4"
    PRIORITIES = { "1" => "High", "2" => "Middle", "3" => "Low" }.freeze
    ENTRY_FIELDS = "@;.01I;.01E;.02I;.03I;.04I;.05I;.06I;.06E;.07I;.08I;.08E;.09I;.09E;.11I"

    # Every clinic's wait list: [{ ien:, clinic_ien:, clinic:, inactive: }].
    # A failed read raises Client::RpcError.
    def lists
      read(LIST_FILE, nil, "@;.01I;.01E;.02I").map do |entry|
        clinic_ien, clinic, inactive = entry[:pieces]
        { ien: entry[:ien].to_i, clinic_ien: clinic_ien.to_i, clinic: clinic.to_s, inactive: inactive == "1" }
      end
    end
    shape :lists, resource: "wait-lists", verb: "GET", path: "/wait-lists/lists"

    # The reasons a list offers: type "A" for adding and "R" for removing,
    # the active ones, as [{ ien:, name: }].
    def reasons(type)
      raise ArgumentError, "type: takes A or R" unless %w[A R].include?(type)

      read(REASON_FILE, nil, "@;.01;.02I;.03I").filter_map do |entry|
        name, kind, inactive = entry[:pieces]
        { ien: entry[:ien].to_i, name: name.to_s } if kind == type && inactive != "I"
      end
    end
    shape :reasons, resource: "wait-lists", verb: "GET", path: "/wait-lists/reasons"

    # A list's entries, open and closed: [{ ien:, patient_dfn:, patient:,
    # priority:, added_on:, added_by:, recall_on:, provider_ien:, provider:,
    # removed_on:, resolution_ien:, resolution:, reason_ien:, reason:,
    # removed_by:, open: }]. Dates are Date or nil. A failed read raises
    # Client::RpcError.
    def entries(list)
      read(ENTRY_FILE, ",#{list.to_i},", ENTRY_FIELDS).map { |entry| entry_row(entry) }
    end
    shape :entries, resource: "wait-lists", verb: "GET", path: "/wait-lists/entries"

    # Add a patient (S-SCH-10.1 to 10.3). Refused with nothing filed when a
    # required value is missing, the list is inactive or not on file, or the
    # reason is not an active reason for adding. Returns { success: true,
    # ien: }, a failure hash, or nil when DDR FILER gives no reply.
    def add(list:, patient_dfn:, added_on:, reason:, recall_on:, priority: nil, provider: nil)
      missing = { patient: patient_dfn, list: list, date_added: added_on, reason: reason, recall_date: recall_on }.select { |_, v| v.to_s.empty? }.keys
      return invalid("#{missing.join(', ')} required") unless missing.empty?
      return invalid("priority: takes #{PRIORITIES.keys.join(', ')}") unless priority.nil? || PRIORITIES.key?(priority.to_s)

      in_context do
        found = lists.find { |row| row[:ien] == list.to_i }
        next not_found("no such wait list") unless found
        next invalid("the wait list is inactive") if found[:inactive]
        next invalid("is not a reason for adding") unless reasons("A").any? { |row| row[:ien] == reason.to_i }

        duz = signed_on_duz
        next invalid("a signed-on DUZ is required") unless duz

        iens = "+1,#{list.to_i},"
        rows = [ row(".01", iens, patient_dfn.to_i), row(".03", iens, fm(added_on)), row(".04", iens, duz),
                 row(".05", iens, fm(recall_on)), row(".09", iens, reason.to_i) ]
        rows << row(".02", iens, priority) if priority
        rows << row(".06", iens, provider.to_i) if provider
        filed = DdrFileman.filer(mode: "ADD", rows: rows)
        next nil if filed.nil?

        filed[:success] ? { success: true, ien: filed[:iens][1].to_i } : failed(filed)
      end
    end
    shape :add, resource: "wait-lists", verb: "POST", path: "/patients/{patient_dfn}/wait-lists"

    # Change an entry (S-SCH-10.4, 10.8): only what is given is sent. A closed
    # entry can be edited too. Returns { success: true }, a failure hash, or
    # nil when DDR FILER gives no reply.
    def update(list:, entry:, reason: nil, priority: nil, provider: nil, recall_on: nil)
      in_context do
        current = find_entry(list, entry)
        next not_found("no such wait list entry") unless current
        next invalid("is not a reason for adding") if reason && reasons("A").none? { |row| row[:ien] == reason.to_i }

        iens = "#{entry.to_i},#{list.to_i},"
        rows = []
        rows << row(".09", iens, reason.to_i) if reason
        rows << row(".02", iens, priority) if priority
        rows << row(".06", iens, provider.to_i) if provider
        rows << row(".05", iens, fm(recall_on)) if recall_on
        next invalid("nothing to change") if rows.empty?

        outcome(DdrFileman.filer(mode: "EDIT", rows: rows))
      end
    end
    shape :update, resource: "wait-lists", verb: "PUT", path: "/wait-lists"

    # Close an open entry (S-SCH-10.5, 10.6, 10.8) with its date and a
    # resolution typed for removal. Refused with nothing filed otherwise, or
    # when it is already closed. Returns { success: true }, a failure hash, or
    # nil when DDR FILER gives no reply.
    def remove(list:, entry:, removed_on:, resolution:)
      return invalid("date removed and resolution required") if removed_on.to_s.empty? || resolution.to_s.empty?

      in_context do
        current = find_entry(list, entry)
        next not_found("no such wait list entry") unless current
        next invalid("the entry is already closed") unless current[:open]
        next invalid("is not a resolution for removing") unless reasons("R").any? { |row| row[:ien] == resolution.to_i }

        duz = signed_on_duz
        next invalid("a signed-on DUZ is required") unless duz

        iens = "#{entry.to_i},#{list.to_i},"
        outcome(DdrFileman.filer(mode: "EDIT", rows: [ row(".07", iens, fm(removed_on)), row(".08", iens, resolution.to_i),
                                                       row(".11", iens, duz) ]))
      end
    end
    shape :remove, resource: "wait-lists", verb: "DELETE", path: "/wait-lists"

    # An entry's COMMENTS as an Array of lines, [] when it has none (S-SCH-10).
    # A failed read raises Client::RpcError.
    def comments(list:, entry:)
      reply = in_context do
        DdrFileman.gets_entry(file: ENTRY_FILE, iens: "#{entry.to_i},#{list.to_i},", fields: COMMENTS_FIELD, flags: "E")
      end
      raise Client::RpcError, "DDR GETS gave no reply for wait list entry #{entry}" if reply.nil?
      raise Client::RpcError, "DDR GETS refused wait list entry #{entry}" if reply[:error] || reply[:malformed]

      Array(reply.dig(:fields, COMMENTS_FIELD, :text))
    end
    shape :comments, resource: "wait-lists", verb: "GET", path: "/wait-lists/comments"

    # Replace an entry's COMMENTS with lines (S-SCH-10.1, 10.4, 10.7): a
    # non-empty Array of Strings, each one line. Refused with nothing filed
    # when the entry is not on file or a line is not a String or holds a line
    # break. A line the wire cannot frame is refused by DDR FILER before
    # anything is sent. Returns { success: true }, a failure hash, or nil
    # when DDR FILER gives no reply.
    def set_comments(list:, entry:, lines:)
      return invalid("lines: takes a non-empty Array of Strings") unless lines.is_a?(Array) && !lines.empty? && lines.all?(String)
      return invalid("a comment line cannot hold a line break") if lines.any? { |line| line.match?(/[\r\n]/) }

      in_context do
        next not_found("no such wait list entry") unless find_entry(list, entry)

        text = lines.each_with_index.to_h { |line, i| [ i + 1, line ] }
        outcome(DdrFileman.filer(mode: "EDIT", rows: [ row(COMMENTS_FIELD, "#{entry.to_i},#{list.to_i},", WP_VALUE) ], iens: text))
      end
    end
    shape :set_comments, resource: "wait-lists", verb: "PUT", path: "/wait-lists/comments"

    private

    COMMENTS_FIELD = "1"
    WP_VALUE = "DDRIENS"
    private_constant :COMMENTS_FIELD, :WP_VALUE

    def entry_row(entry)
      dfn, patient, priority, added_on, added_by, recall_on, provider_ien, provider, removed_on, resolution_ien,
        resolution, reason_ien, reason, removed_by = entry[:pieces]
      { ien: entry[:ien].to_i, patient_dfn: dfn.to_i, patient: patient.to_s, priority: priority.to_s,
        added_on: date(added_on), added_by: id_or_nil(added_by), recall_on: date(recall_on),
        provider_ien: id_or_nil(provider_ien), provider: provider.to_s, removed_on: date(removed_on),
        resolution_ien: id_or_nil(resolution_ien), resolution: resolution.to_s, reason_ien: id_or_nil(reason_ien),
        reason: reason.to_s, removed_by: id_or_nil(removed_by), open: removed_on.to_s.empty? }
    end

    def find_entry(list, entry) = entries(list).find { |row| row[:ien] == entry.to_i }

    def read(file, iens, fields)
      listed = in_context { DdrFileman.lister(file: file, iens: iens, fields: fields, flags: "IP") }
      raise Client::RpcError, "DDR LISTER gave no reply for ##{file}" if listed.nil?
      raise Client::RpcError, "DDR LISTER refused ##{file}" if listed[:error] || listed[:more]

      listed[:entries]
    end

    def row(field, iens, value) = { file: ENTRY_FILE, field: field, iens: iens, value: value }

    def fm(value) = FilemanDateParser.to_fileman(value.to_date).to_i

    def date(text) = text.to_s.empty? ? nil : FilemanDateParser.parse_date(text)

    def id_or_nil(text) = text.to_s.match?(/\A[1-9]\d*\z/) ? text.to_i : nil

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
  end
end
