# frozen_string_literal: true

module RpmsRpc
  # Symbolic API for radiology / diagnostic-imaging data.
  # Underlying RPCs (ORWRA family): REPORT LIST, REPORT.
  module Radiology
    extend self

    # Radiology reports for a patient. Returns an Array of report hashes
    # (empty for invalid / unknown DFN).
    #
    # Each hash: { ien:, exam_name:, cpt_code:, status:, exam_date:,
    #              report_date:, radiologist_duz:, radiologist_name:,
    #              impression:, imaging_study_ien:, report_text: }
    def for_patient(dfn)
      return [] if dfn.nil? || dfn.to_s.empty? || dfn.to_i <= 0
      return [] unless RpmsRpc.client.supports?(:orwra_radiology_reports)

      Array(DataMapper.radiology_list.fetch_many(dfn.to_s)).map { |r| apply_defaults(r) }
    end

    # Single radiology report text by IEN. Returns the raw text blob
    # (string) or nil if not found / invalid input. Production callers may
    # want to apply site-specific parsing on the returned text.
    def find(ien)
      return nil if ien.nil? || ien.to_s.empty?
      return nil unless RpmsRpc.client.supports?(:orwra_radiology_reports)

      text = DataMapper.radiology_report.fetch_text(ien.to_s)
      return nil if text.nil? || (text.respond_to?(:empty?) && text.empty?)

      text
    end

    private

    def apply_defaults(row)
      row.merge(status: blank?(row[:status]) ? "final" : row[:status])
    end

    def blank?(val)
      val.nil? || val.to_s.empty?
    end
  end
end
