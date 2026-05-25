# frozen_string_literal: true

module RpmsRpc
  # Symbolic API for FHIR Goal data.
  # Underlying RPCs (ORQQGO family): LIST, GET.
  #
  # Each goal: { ien:, goal_text:, lifecycle_status:, achievement_status:,
  #              category:, priority:, start_date:, target_date:,
  #              status_date:, provider_duz:, provider_name:, note:,
  #              patient_dfn: (find only) }
  module Goal
    extend self

    DEFAULT_LIFECYCLE_STATUS = "active"

    def for_patient(dfn)
      return [] if blank?(dfn) || dfn.to_i <= 0

      raw = DataMapper.goal_list.fetch_many(dfn.to_s)
      Array(raw).map { |row| apply_defaults(row) }
    end

    # Single goal by IEN. GET response is hybrid: first line is field-based,
    # any subsequent lines are free-text note (joined here).
    def find(ien)
      return nil if blank?(ien)

      response = RpmsRpc.client.call_rpc("ORQQGO GET", ien.to_s)
      return nil if response.nil? || (response.respond_to?(:empty?) && response.empty?)

      lines = response.is_a?(Array) ? response : [ response.to_s ]
      first = lines.first
      return nil if first.nil? || first.to_s.empty?

      parsed = DataMapper.goal_detail.parse_one(first, extras: { ien: ien })
      return nil if parsed.nil?

      note = lines.length > 1 ? lines[1..].join("\n") : nil
      apply_defaults(parsed.merge(note: blank?(note) ? nil : note))
    end

    private

    def apply_defaults(row)
      row.merge(
        lifecycle_status: blank?(row[:lifecycle_status]) ? DEFAULT_LIFECYCLE_STATUS : row[:lifecycle_status]
      )
    end

    def blank?(val)
      val.nil? || val.to_s.empty?
    end
  end
end
