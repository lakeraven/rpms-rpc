# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for IHS clinical reminders. Fires at encounter open to
  # surface what's due/applicable/satisfied for the patient.
  # Underlying RPC: BGOTRG GETSUM.
  module Reminders
    extend self

    STATUS_MAP = {
      "DUE"        => :due,
      "APPLICABLE" => :applicable,
      "SATISFIED"  => :satisfied
    }.freeze

    def for_visit(dfn, visit_ien)
      return [] if invalid_id?(dfn) || invalid_id?(visit_ien)

      Array(DataMapper.reminder_summary.fetch_many(dfn.to_s, visit_ien.to_s)).map { |row| decorate(row) }
    end

    private

    def decorate(row)
      code = row[:status_code].to_s
      {
        id: row[:id],
        name: row[:name],
        status: STATUS_MAP[code] || code.downcase.to_sym,
        priority: row[:priority],
        due_date: row[:due_date]
      }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
