# frozen_string_literal: true

module RpmsRpc
  # Symbolic API for FHIR CarePlan data.
  # Underlying RPCs (ORQQCP family): LIST, GET.
  #
  # for_patient entries: { ien:, title:, status:, intent:, category:, start_date:,
  #   end_date:, author_duz:, author_name:, goal_iens:, activity:, description:, note: }
  #
  # find result includes the same keys plus :patient_dfn (echoed from the GET
  # response body). :note is always present (default nil) for shape parity.
  module CarePlan
    extend self

    DEFAULT_STATUS   = "active"
    DEFAULT_INTENT   = "plan"
    DEFAULT_CATEGORY = "assess-plan"

    # All care plans for a patient. Returns [] for invalid / unknown DFN.
    def for_patient(dfn)
      return [] if blank?(dfn) || dfn.to_i <= 0

      raw = DataMapper.care_plan_list.fetch_many(dfn.to_s)
      Array(raw).map { |row| apply_defaults(row) }
    end

    # Single care plan by IEN. Returns a hash or nil if not found / invalid.
    # The ORQQCP GET response is a hybrid: first line is field-based, any
    # subsequent lines are free-text description (joined here).
    def find(ien)
      return nil if blank?(ien)

      response = RpmsRpc.client.call_rpc(DataMapper.care_plan_detail.rpc_name, ien.to_s)
      return nil if response.nil? || (response.respond_to?(:empty?) && response.empty?)

      lines = response.is_a?(Array) ? response : [ response.to_s ]
      first = lines.first
      return nil if first.nil? || first.to_s.empty?

      parsed = DataMapper.care_plan_detail.parse_one(first, extras: { ien: ien })
      return nil if parsed.nil?

      description = lines.length > 1 ? lines[1..].join("\n") : nil
      apply_defaults(parsed.merge(
        description: blank?(description) ? nil : description,
        note:        nil
      ))
    end

    private

    def apply_defaults(row)
      row.merge(
        status:   blank?(row[:status])   ? DEFAULT_STATUS   : row[:status],
        intent:   blank?(row[:intent])   ? DEFAULT_INTENT   : row[:intent],
        category: blank?(row[:category]) ? DEFAULT_CATEGORY : row[:category]
      )
    end

    def blank?(val)
      val.nil? || val.to_s.empty?
    end
  end
end
