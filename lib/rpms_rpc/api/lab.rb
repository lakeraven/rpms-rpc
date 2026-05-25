# frozen_string_literal: true

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
      return [] if dfn.nil? || dfn.to_s.empty? || dfn.to_i <= 0

      raw = DataMapper.lab_result_list.fetch_many(dfn.to_s, *date_range_params(days))
      Array(raw).map { |row| decorate_result(row) }
    end

    # Only the abnormal results within the window.
    def abnormal(dfn, days: 90)
      for_patient(dfn, days: days).select { |r| r[:abnormal] }
    end

    # DiagnosticReport-style panel aggregation for a patient.
    # Each hash: { ien:, panel_name:, performed_at_raw:, status:, performing_lab: }
    def reports(dfn)
      return [] if dfn.nil? || dfn.to_s.empty? || dfn.to_i <= 0

      Array(DataMapper.lab_report_list.fetch_many(dfn.to_s))
    end

    # Single lab / panel detail. Returns a hash or nil if not found.
    # Parses the text-blob response (LABEL: VALUE lines) into a structured hash.
    def find(dfn, lab_ien)
      return nil if dfn.nil? || lab_ien.nil?
      return nil if dfn.to_s.empty? || lab_ien.to_s.empty?

      key = "#{dfn}|#{lab_ien}"
      text = DataMapper.lab_report.fetch_text(key)
      return nil if text.nil? || (text.respond_to?(:empty?) && text.empty?)

      parse_detail(text, lab_ien)
    end

    private

    # ORWLRR RESULT LIST takes (dfn, from_mm_dd_yyyy, to_mm_dd_yyyy).
    # The MockClient keys on the first param (dfn) so the date params are
    # transport-only; tests can ignore them. Returned for parity with the
    # production RPC contract.
    def date_range_params(days)
      to_date   = Date.today
      from_date = to_date - days
      [ from_date.strftime("%m/%d/%Y"), to_date.strftime("%m/%d/%Y") ]
    end

    def decorate_result(row)
      flag = row[:abnormal_flag]
      row.merge(abnormal: !flag.nil? && flag.to_s != "" && flag.to_s.upcase != "N")
    end

    # Parse "LABEL: VALUE" text-blob into the detail-hash shape.
    # Tolerant of label aliases (TEST/TEST NAME, COLLECTED/COLLECTION DATE, etc.).
    def parse_detail(text, lab_ien)
      detail = { ien: lab_ien.to_i, components: [] }
      lines = text.is_a?(String) ? text.split(/\r?\n/) : Array(text)

      lines.each do |line|
        next if line.nil? || line.strip.empty?
        next unless line.include?(":")

        label, value = line.split(":", 2).map(&:strip)
        normalized = label.to_s.upcase
        case normalized
        when "TEST", "TEST NAME"         then detail[:test_name]         = value
        when "RESULT"                    then detail[:result]            = value
        when "UNITS"                     then detail[:units]             = value
        when "REFERENCE RANGE",
             "REF RANGE",
             "NORMAL RANGE"              then detail[:reference_range]   = value
        when "COLLECTED",
             "COLLECTION DATE"           then detail[:collection_date]   = value
        when "RECEIVED"                  then detail[:received_date]     = value
        when "RESULTED",
             "RESULT DATE"               then detail[:resulted_date]     = value
        when "STATUS"                    then detail[:status]            = value.to_s.downcase
        when "ORDERING PROVIDER",
             "PROVIDER"                  then detail[:ordering_provider] = value
        when "PERFORMING LAB", "LAB"     then detail[:performing_lab]    = value
        when "SPECIMEN"                  then detail[:specimen]          = value
        when "COMMENTS", "NOTES"         then detail[:comments]          = value
        when "INTERPRETATION"            then detail[:interpretation]    = value
        end
      end

      detail
    end
  end
end
