# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for referral records. Read via referral_search /
  # referral_detail; write via the BMC RCIS RPCs (see {add}).
  module Referral
    extend self

    # The broker option the BMC RPCs are registered under.
    CONTEXT = "BMCRPC"

    # STATUS OF REFERRAL (file 90001, field .15) code for a cancelled
    # referral: X, CLOSED-NOT COMPLETED. RCIS's own reports skip X as
    # "cancelled" (BMCRR121.m:39, BMCRR41.m:38).
    CANCELLED_STATUS = "X"

    def for_patient(dfn)
      DataMapper.referral_search.fetch_many(dfn.to_s)
    end

    def find(ien)
      return nil if ien.nil?

      DataMapper.referral_detail.fetch_one(ien.to_s)
    end

    def add(*params)
      bmc_scalar_result(:bmc_add_referral, *params)
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

    # Cancel a referral: file its status as CANCELLED_STATUS through BMC
    # REFERRAL STATUS UPDATE (UPDTSTRF^BMCRPC3(RSLT,REFIEN,STATUS),
    # BMCRPC3.m:176-187), under CONTEXT. RCIS has no delete; this replaces
    # the removed `delete`. The routine files field .15 and nothing else, so
    # there is no reason argument: a cancellation reason is not filed by it.
    #
    # Returns { success:, message:, raw: }. The routine answers "1" when it
    # filed and "~`0^message" when it refused. On builds without
    # rpms-ops#702 its refusal path QUITs with a value under a broker that
    # DOes the tag, and the call raises Client::RpcError instead.
    def cancel(ien)
      return failure if invalid_id?(ien)

      in_bmc_context do
        result = bmc_scalar_result(:bmc_referral_status_update, ien.to_s.strip, CANCELLED_STATUS)
        refusal = result[:raw].to_s.match(/\A~`0\^?(.*)\z/m)
        refusal ? result.merge(success: false, message: refusal[1].strip) : result
      end
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

    # NOT IMPLEMENTED — and honestly so (#217). The former binding,
    # BGOREF SET, is the personal REFUSALS writer (SET^BGOREF files
    # ^AUPNPREF via $$REFSET2^BGOUTL2 — BGOREF.m:8,29): "creating a
    # referral" was filing a refusal record. The real referral writer is
    # BMC ADD REFERRAL (SETREFRL^BMCRPC2), whose 39 positional formals
    # (referral date, type, IO/RO, ICD/CPT categories, purpose, priority,
    # …) cannot be honestly derived from this method's small params hash —
    # use {add} with the full BMC parameter list instead.
    def create(dfn, params)
      raise ArgumentError, "params must be a Hash" unless params.is_a?(Hash)
      return failure if invalid_id?(dfn)

      {
        success: false,
        error: :not_implemented,
        message: "Referral.create has no faithful RPC binding: BGOREF SET writes " \
                 "refusals, not referrals. Use Referral.add (BMC ADD REFERRAL = " \
                 "SETREFRL^BMCRPC2) with the full RCIS parameter list.",
        raw: nil
      }
    end

    private

    def failure
      { success: false, ien: nil, raw: nil }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    # Run the block with CONTEXT bound, restoring the caller's option; a
    # client that cannot scope contexts runs it as-is.
    def in_bmc_context(&block)
      client = RpmsRpc.client
      return block.call unless client.respond_to?(:with_context)

      client.with_context(CONTEXT, &block)
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
