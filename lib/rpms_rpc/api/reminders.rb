# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"

module RpmsRpc
  # Symbolic API for clinical reminders, read the way RPMS evaluates them
  # for the EHR (#238).
  #
  # Underlying RPC: ORQQPXRM REMINDERS APPLICABLE -> EVALCOVR^ORQQPX
  # (ORQQPX.m:232-236), which joins the cover-sheet reminder list to the
  # reminder engine's evaluation, AVAL^PXRMRPCA (PXRMRPCA.m:49-82). The
  # reply layout and its sentinels are documented on the
  # :reminders_applicable mapping (mappings/stock_vista.rb).
  #
  # RPMS keys this read by patient and hospital LOCATION, not by visit:
  # there is no visit-keyed reminder method, so this module has none
  # (ADR 0008 section 3).
  module Reminders
    extend self
    extend Shape::Declarable

    # The DUE FLAG piece, as AVAL sets it (PXRMRPCA.m:56-67). 2 is the
    # routine's default ("Not applicable is default", :56). Any other value
    # is not something RPMS emits, so it maps to nil rather than a guess.
    STATUS_BY_DUE_FLAG = {
      0 => :applicable,
      1 => :due,
      2 => :not_applicable,
      3 => :error,
      4 => :cannot_be_determined
    }.freeze

    # The literal the engine writes in the due-date piece when nothing has
    # resolved the reminder yet (PXRMDATE.m:132).
    DUE_NOW = "DUE NOW"

    # Reminders the engine evaluated for +dfn+ at +location_ien+ (#44),
    # one hash per reply row, not-applicable rows included as RPMS
    # returns them. +location_ien+ may be omitted: REMLIST guards the
    # location with `I +LOC` (ORQQPX.m:194).
    def applicable(dfn, location_ien = nil)
      return [] if invalid_id?(dfn)

      rows = DataMapper.reminders_applicable.fetch_many(dfn.to_s, location_ien.to_s)
      Array(rows).map { |row| decorate(row) }
    end
    shape :applicable, resource: "reminders", verb: "GET", path: "/patients/{dfn}/reminders/applicable"

    # The cover-sheet reminders for +location_ien+, not evaluated: each
    # REMINDER DEFINITION (#811.9) IEN, in cover-sheet order. ORQQPXRM
    # REMINDERS UNEVALUATED (LIST^ORQQPXRM -> GETLIST^ORQQPX) builds the
    # list from the user, location, service, division, system and package
    # (REMLIST^ORQQPX); the patient is sent, as VueCentric sends it, and not
    # read. A -N^text reply raises Client::RpcError.
    def unevaluated(dfn, location_ien = nil)
      return [] if invalid_id?(dfn)

      DataMapper.reminders_unevaluated.lines!(dfn.to_s, location_ien.to_s).map do |line|
        raise Client::RpcError, "ORQQPXRM REMINDERS UNEVALUATED answered #{line.inspect}, not a reminder IEN" unless line.match?(/\A[1-9]\d*\z/)

        line.to_i
      end
    end
    shape :unevaluated, resource: "reminders", verb: "GET", path: "/patients/{dfn}/reminders/unevaluated"

    # The reminder categories the PXRM CPRS LOOKUP CATEGORIES parameter
    # names for this user and +location_ien+, as a flat tree:
    #
    #   [{ id:, kind: :category, name:, parent_id: }, ...
    #    { id:, kind: :reminder, name:, parent_id:, reminder_ien:, has_dialog: }]
    #
    # ORQQPXRM REMINDER CATEGORIES (CATEGORY^PXRMRPCA). parent_id is the
    # id of the enclosing category (0 at the top). [] when the parameter
    # names none; "^Error: text" (the parameter read failed) and a -N^text
    # reply raise Client::RpcError.
    def categories(dfn, location_ien = nil)
      return [] if invalid_id?(dfn)

      DataMapper.reminder_categories.lines!(dfn.to_s, location_ien.to_s).map { |line| category_row(line) }
    end
    shape :categories, resource: "reminders", verb: "GET", path: "/patients/{dfn}/reminders/categories"

    # The education topics (#9999999.09) a reminder's findings name,
    # directly or through a reminder term: [{ ien:, name:, print_name: }].
    # ORQQPXRM EDUCATION SUMMARY (EDL^PXRMRPCB). [] for a reminder with
    # none.
    def education_topics(reminder_ien)
      return [] if invalid_id?(reminder_ien)

      DataMapper.reminder_education_topics.fetch_many!(reminder_ien.to_s).map do |row|
        { ien: row[:ien], name: row[:name], print_name: row[:print_name] }
      end
    end
    shape :education_topics, resource: "reminders", verb: "GET", path: "/reminders/{reminder_ien}/education-topics"

    # The web references for a reminder: its own (#811.9, multiple 50),
    # then the site's general ones (#800), as
    # [{ url:, title:, description: [lines] }]. ORQQPXRM REMINDER WEB
    # (WEB^PXRMRPCA). A line that is neither a "1^" site nor a "2^"
    # description of the site before it raises Client::RpcError.
    def web_references(reminder_ien)
      return [] if invalid_id?(reminder_ien)

      DataMapper.reminder_web_references.lines!(reminder_ien.to_s).each_with_object([]) do |line, sites|
        kind, id, rest = line.split("^", 3)
        if kind == "1"
          url, title = rest.to_s.split("^", 2)
          sites << { id: id.to_i, url: url, title: title.to_s.empty? ? nil : title, description: [] }
        elsif kind == "2" && sites.last && sites.last[:id] == id.to_i
          sites.last[:description] << rest.to_s
        else
          raise Client::RpcError, "ORQQPXRM REMINDER WEB answered #{line.inspect}"
        end
      end.map { |site| site.except(:id) }
    end
    shape :web_references, resource: "reminders", verb: "GET", path: "/reminders/{reminder_ien}/web-references"

    private

    def category_row(line)
      id, kind, name, parent, reminder, dialog = line.split("^", -1)
      raise Client::RpcError, RpmsRpc.sanitize_error("ORQQPXRM REMINDER CATEGORIES answered #{line.inspect}") unless id.to_s.match?(/\A\d+\z/) && %w[C R].include?(kind)

      row = { id: id.to_i, kind: kind == "C" ? :category : :reminder, name: name.to_s.empty? ? nil : name, parent_id: parent.to_i }
      return row if kind == "C"

      row.merge(reminder_ien: reminder.to_i, has_dialog: dialog == "1")
    end

    def decorate(row)
      raw_due = row[:due_date].to_s
      {
        id: row[:ien],
        name: row[:print_name],
        status: STATUS_BY_DUE_FLAG[row[:due_flag]],
        due_flag: row[:due_flag],
        due_date: FilemanDateParser.parse_date(raw_due),
        due_now: raw_due == DUE_NOW,
        last_done: row[:last_done],
        priority: row[:priority],
        has_dialog: row[:dialog] == true
      }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
