# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for referral records. Read via referral_search /
  # referral_detail; write via BGOREF SET.
  module Referral
    extend self

    # Wire field order for BGOREF SET. Field positions are best-effort
    # pending wider trace capture; this list locks the order so a caller's
    # Hash key insertion order can't reshuffle the payload mid-flight.
    CREATE_FIELDS = %i[provider_ien specialty reason priority requested_date].freeze

    def for_patient(dfn)
      DataMapper.referral_search.fetch_many(dfn.to_s)
    end

    def find(ien)
      return nil if ien.nil?

      DataMapper.referral_detail.fetch_one(ien.to_s)
    end

    def delete(ien, reason: nil)
      DataMapper.referral_delete.fetch_one(ien.to_s, reason)
    end

    def add(*params)
      bmc_scalar_result(:bmc_add_referral, *params)
    end

    def add_secondary(*params)
      bmc_scalar_result(:bmc_add_secondary_referral, *params)
    end

    def update(ien, *params)
      bmc_scalar_result(:bmc_update_referral, ien, *params)
    end

    def print(ien, *params)
      bmc_scalar_result(:bmc_print_referral, ien.to_s, *params)
    end

    def update_status(ien, status, *params)
      bmc_scalar_result(:bmc_referral_status_update, ien.to_s, status.to_s, *params)
    end

    def update_consultation_status(consultation_ien, status, *params)
      bmc_scalar_result(:bmc_consultation_status_update, consultation_ien.to_s, status.to_s, *params)
    end

    def purposes(*params)
      bmc_many(:bmc_purpose_of_referral_list, *params)
    end

    def reference_data(*params)
      bmc_many(:bmc_reference_data, *params)
    end

    def users_providers(*params)
      bmc_many(:bmc_users_providers, *params)
    end

    def providers(*params)
      bmc_many(:bmc_providers, *params)
    end

    def search_referred_to(*params)
      bmc_many(:bmc_search_referred_to, *params)
    end

    def rcis_templates(*params)
      bmc_many(:bmc_rcis_template_list, *params)
    end

    def rcis_template_detail(template_ien, *params)
      bmc_text(:bmc_rcis_template_detail, template_ien.to_s, *params)
    end

    def patient_eligibility_status(dfn, *params)
      return nil unless bmc_supported?

      DataMapper.bmc_patient_eligibility_status.fetch_one(dfn.to_s, *params)
    end

    def patient_face_sheet(dfn, *params)
      bmc_text(:bmc_patient_face_sheet, dfn.to_s, *params)
    end

    def patient_health_summary(dfn, *params)
      bmc_text(:bmc_patient_health_summary, dfn.to_s, *params)
    end

    def health_summary_types(*params)
      bmc_many(:bmc_health_summary_type, *params)
    end

    def check_year_site_param(*params)
      bmc_scalar_result(:bmc_check_year_site_param, *params)
    end

    def add_c32_print_log(*params)
      bmc_scalar_result(:bmc_add_c32_print_log, *params)
    end

    def create(dfn, params)
      raise ArgumentError, "params must be a Hash" unless params.is_a?(Hash)
      return failure if invalid_id?(dfn)

      payload = CREATE_FIELDS.map { |k| params[k].to_s }.join("^")
      raw = DataMapper.referral_create.fetch_scalar(dfn.to_s, payload)

      saved_ien = raw.to_s.match(/\A\d+/)&.to_s&.to_i
      {
        success: !saved_ien.nil? && saved_ien.positive?,
        ien: saved_ien,
        raw: raw
      }
    end

    private

    def failure
      { success: false, ien: nil, raw: nil }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    def bmc_supported?
      RpmsRpc.client.supports?(:bmc_referral_workflow)
    end

    def bmc_many(mapping_name, *params)
      return [] unless bmc_supported?

      DataMapper[mapping_name].fetch_many(*params.map(&:to_s))
    end

    def bmc_text(mapping_name, *params)
      return nil unless bmc_supported?

      DataMapper[mapping_name].fetch_text(*params.map(&:to_s))
    end

    def bmc_scalar_result(mapping_name, *params)
      return unsupported_result unless bmc_supported?

      raw = DataMapper[mapping_name].fetch_scalar(*params.map(&:to_s))
      result_from_raw(raw)
    end

    def result_from_raw(raw)
      line = raw.to_s.strip
      return { success: false, raw: raw } if line.empty?

      success = line.start_with?("1") || line.match?(/\A[1-9]\d*\z/)
      message = line.sub(/\A[01]\^/, "").strip
      { success: success, message: message.empty? ? nil : message, raw: raw }
    end

    def unsupported_result
      { success: false, error: "BMC referral workflow not available on this server", raw: nil }
    end
  end
end
