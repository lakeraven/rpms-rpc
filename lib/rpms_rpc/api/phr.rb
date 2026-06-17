# frozen_string_literal: true

require "date"

module RpmsRpc
  # Symbolic API for Personal Health Record and CCD gateway RPCs.
  module Phr
    extend self

    DEFAULT_CCD_TITLE = "Clinical Document"
    DEFAULT_CCD_TYPE = "CCD"

    def enrollment_status(dfn)
      return disabled_status("Invalid patient") if invalid_id?(dfn)

      # BEHOCCD PHR is line-based, not caret-delimited:
      #   line 0: "1" (has access) or "0" (no access)
      #   line 1: optional human-readable message
      # fetch_one normalizes to first line only, which would drop the
      # message and would fail to coerce "1Some text" forms — so the
      # parsing is done here against the raw response.
      response = RpmsRpc.client.call_rpc(DataMapper.phr_access.rpc_name, dfn.to_s)
      return disabled_status("No response") if blank_response?(response)

      lines = response.is_a?(Array) ? response : response.to_s.split(/\r?\n/)
      status = lines.first.to_s.strip
      message = lines[1].to_s.strip
      has_access = status == "1"

      {
        enrolled: has_access,
        has_access: has_access,
        message: message.empty? ? default_status_message(has_access) : message
      }
    end

    def has_access?(dfn)
      enrollment_status(dfn)[:has_access]
    end

    def for_patient(dfn, start_date: Date.today - 365, end_date: Date.today)
      return [] if invalid_id?(dfn)

      key = "#{dfn}^#{format_date(start_date)}^#{format_date(end_date)}"
      Array(DataMapper.ccd_document.fetch_many(key)).map { |row| decorate_ccd(row) }
    end

    def find(ien)
      return nil if invalid_id?(ien)

      content = DataMapper.immunization_text.fetch_text(ien.to_s)
      return nil if blank?(content)

      { content: content, format: detect_format(content) }
    end

    def counts(dfn)
      return zero_counts if invalid_id?(dfn)

      row = DataMapper.immunization_count.fetch_one(dfn.to_s)
      return zero_counts if row.nil?

      total = row[:total].to_i
      reconciled = row[:reconciled].to_i
      { total: total, reconciled: reconciled, pending: total - reconciled }
    end

    def referrals_for_visits(visit_iens)
      ids = Array(visit_iens).reject { |ien| invalid_id?(ien) }
      return [] if ids.empty?

      DataMapper.ccd_referral.fetch_many(ids.join("^"))
    end

    def patient_direct_address(dfn)
      direct_address(:phr_patient_direct, dfn)
    end

    def provider_direct_address(duz)
      direct_address(:phr_provider_direct, duz)
    end

    def facility_direct_domain(location_ien)
      direct_address(:phr_facility_direct, location_ien)
    end

    def record_access(dfn, access_type: "VIEW", date: nil)
      return nil if invalid_id?(dfn)
      return nil unless RpmsRpc.client.supports?(:bphr_phr_endpoints)

      date ||= Date.today
      param = "#{dfn}^#{access_type}^#{format_date(date)}"
      DataMapper.phr_record_access.fetch_scalar(param)
    end

    private

    def decorate_ccd(row)
      row.merge(
        title: blank?(row[:title]) ? DEFAULT_CCD_TITLE : row[:title],
        type: blank?(row[:type]) ? DEFAULT_CCD_TYPE : row[:type]
      )
    end

    def direct_address(mapping_name, id)
      return nil if invalid_id?(id)
      return nil unless RpmsRpc.client.supports?(:bphr_phr_endpoints)

      row = DataMapper[mapping_name].fetch_one(id.to_s)
      return nil if row.nil?

      address = row[:direct_address].to_s.strip
      return nil if address.empty? || address.start_with?("-1")

      address
    end

    def detect_format(content)
      if content.include?("<?xml") || content.include?("<ClinicalDocument")
        "xml"
      elsif content.include?("<html") || content.include?("<HTML")
        "html"
      else
        "text"
      end
    end

    def zero_counts
      { total: 0, reconciled: 0, pending: 0 }
    end

    def disabled_status(message)
      { enrolled: false, has_access: false, message: message }
    end

    def default_status_message(has_access)
      has_access ? "PHR access enabled" : "PHR not enrolled"
    end

    def format_date(date)
      date.strftime("%m/%d/%Y")
    end

    def invalid_id?(value)
      blank?(value) || value.to_i <= 0
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def blank_response?(response)
      response.nil? || (response.respond_to?(:empty?) && response.empty?)
    end
  end
end
