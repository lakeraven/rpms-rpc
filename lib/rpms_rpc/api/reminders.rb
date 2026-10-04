# frozen_string_literal: true

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

    private

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
