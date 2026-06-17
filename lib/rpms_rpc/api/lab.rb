# frozen_string_literal: true

require "date"

module RpmsRpc
  # Symbolic API for laboratory data.
  # Underlying RPCs (ORWLRR family): RESULT LIST, REPORT LIST, REPORT.
  module Lab
    extend self

    # Recent labs for a patient. Defaults to the last 90 days.
    # Returns an Array of result hashes (empty for invalid/unknown DFN).
    #
    # Each hash: { ien:, test_name:, result:, units:, reference_range:,
    #              abnormal:, abnormal_flag:, collection_date:, status: }
    def for_patient(dfn, days: 90)
      return [] if blank?(dfn) || dfn.to_i <= 0
      return [] unless RpmsRpc.client.supports?(:orwlrr_lab_reports)

      raw = DataMapper.lab_result_list.fetch_many(build_list_param(dfn, days))
      Array(raw).map { |row| decorate_result(row) }
    end

    # Only the abnormal results within the window.
    def abnormal(dfn, days: 90)
      for_patient(dfn, days: days).select { |r| r[:abnormal] }
    end

    # DiagnosticReport-style panel aggregation for a patient.
    def reports(dfn)
      return [] if blank?(dfn) || dfn.to_i <= 0
      return [] unless RpmsRpc.client.supports?(:orwlrr_lab_reports)

      Array(DataMapper.lab_report_list.fetch_many(dfn.to_s)).map { |r| apply_report_defaults(r) }
    end

    # Single lab / panel detail. Returns a hash or nil if not found.
    # The ORWLRR REPORT RPC takes a single composite param: "dfn^lab_ien".
    # Response is a text blob: LABEL: VALUE lines plus optional caret-delimited
    # component lines for panel tests.
    def find(dfn, lab_ien)
      return nil if blank?(dfn) || blank?(lab_ien)
      return nil unless RpmsRpc.client.supports?(:orwlrr_lab_reports)

      key = "#{dfn}^#{lab_ien}"
      text = DataMapper.lab_report.fetch_text(key)
      return nil if text.nil? || (text.respond_to?(:empty?) && text.empty?)

      parse_detail(text, lab_ien)
    end

    # Build the ORWLRR RESULT LIST composite param ("dfn^from^to").
    # Public for tests / observability.
    def build_list_param(dfn, days = 90)
      to_date   = Date.today
      from_date = to_date - days
      "#{dfn}^#{from_date.strftime('%m/%d/%Y')}^#{to_date.strftime('%m/%d/%Y')}"
    end

    private

    def decorate_result(row)
      flag = row[:abnormal_flag]
      row.merge(abnormal: !blank?(flag) && flag.to_s.upcase != "N")
    end

    def apply_report_defaults(row)
      row.merge(status: blank?(row[:status]) ? "final" : row[:status])
    end

    # Parse the ORWLRR REPORT text-blob response. Lines come in two shapes:
    # - "LABEL: VALUE" — assigned to a named attribute on the detail hash
    # - "field0^field1^field2^..." — a panel component
    def parse_detail(text, lab_ien)
      detail = { ien: lab_ien.to_i, components: [] }
      lines = text.is_a?(String) ? text.split(/\r?\n/) : Array(text)

      lines.each do |line|
        next if line.nil? || line.strip.empty?

        if label_value?(line)
          assign_label(detail, line)
        elsif line.include?("^")
          component = parse_component(line)
          detail[:components] << component if component
        end
      end

      detail[:abnormal] = overall_abnormal(detail)
      detail
    end

    # A line is "LABEL: VALUE" only if it has a colon and the part before
    # the first colon contains no caret (carets indicate a component line).
    def label_value?(line)
      return false unless line.include?(":")

      head = line.split(":", 2).first.to_s
      !head.empty? && !head.include?("^")
    end

    def assign_label(detail, line)
      label, value = line.split(":", 2).map { |s| s.to_s.strip }
      case label.upcase
      when "TEST", "TEST NAME"
        detail[:test_name] = value
      when "RESULT"
        detail[:result] = value
      when "UNITS"
        detail[:units] = value
      when "REFERENCE RANGE", "REF RANGE", "NORMAL RANGE"
        detail[:reference_range] = value
      when "ABNORMAL FLAG"
        detail[:abnormal_flag] = value
      when "COLLECTED", "COLLECTION DATE"
        detail[:collection_date] = parse_datetime(value)
      when "RECEIVED"
        detail[:received_date] = parse_datetime(value)
      when "RESULTED", "RESULT DATE"
        detail[:resulted_date] = parse_datetime(value)
      when "STATUS"
        detail[:status] = value.to_s.downcase
      when "ORDERING PROVIDER", "PROVIDER"
        detail[:ordering_provider] = value
      when "PERFORMING LAB", "LAB"
        detail[:performing_lab] = value
      when "SPECIMEN"
        detail[:specimen] = value
      when "COMMENTS", "NOTES"
        detail[:comments] = value
      when "INTERPRETATION"
        detail[:interpretation] = value
      end
    end

    def parse_component(line)
      fields = line.split("^", -1)
      return nil if fields.length < 3

      flag = fields[4]
      {
        name:            fields[0],
        result:          fields[1],
        units:           fields[2],
        reference_range: fields[3],
        abnormal:        !blank?(flag) && flag.to_s.upcase != "N",
        abnormal_flag:   flag
      }
    end

    def overall_abnormal(detail)
      if detail[:components].any?
        detail[:components].any? { |c| c[:abnormal] }
      else
        flag = detail[:abnormal_flag]
        !blank?(flag) && flag.to_s.upcase != "N"
      end
    end

    def parse_datetime(value)
      return nil if blank?(value)

      FilemanDateParser.parse_datetime(value) || value
    end

    def blank?(val)
      val.nil? || val.to_s.empty?
    end
  end
end
