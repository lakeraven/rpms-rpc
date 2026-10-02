# frozen_string_literal: true

require_relative "../mappings"
require_relative "../context_scope"

module RpmsRpc
  # Symbolic API for referral records. Read via referral_search /
  # referral_detail; write via the BMC RCIS RPCs (see {add}).
  #
  # ## Context — this module binds it, callers do not (rpms-rpc#258)
  #
  # RPC registration is OPTION-scoped (RpmsRpc::ContextScope): the broker
  # answers "may this session run this RPC?" from the RPC multiple of the
  # option bound right now. On a built 9.0 image the BMC* RPCs are listed in
  # the RPC multiple of ONE file-19 option, BMCRPC ("the broker context for
  # RCIS component in the EHR GUI"; 22 entries: the 21 BMC names below plus
  # ORWDXIHS CLININD), and in no other — not the option a CIA sign-on binds
  # (CIAV VUECENTRIC) and not OR CPRS GUI CHART. A user without XUPROGMODE
  # calling them under the sign-on option is simply denied.
  #
  # So every method that reaches the wire scopes itself to BMCRPC via
  # ContextScope.scoped (bind, run, restore the caller's option), the way
  # RpmsRpc::Agg does for AGGRPC. That includes the bmc_supported? probe:
  # BMC GET REFERENCE DATA is in that same multiple, so probed under the
  # caller's option it would answer "not here" and every method would
  # short-circuit to "BMC referral workflow not available". A client that
  # cannot scope contexts runs as-is. A programmer-key session bypasses the
  # check either way, so only a non-programmer run is evidence of this bind.
  #
  # Known gap: {delete} calls BMCRPC DELREFRL, which is registered in NO
  # option on that image (rpms-rpc#207 lists it as an invented name); the
  # bind cannot make an unregistered RPC runnable.
  module Referral
    extend self

    # The context option the BMC* RPCs are registered under — see the module
    # doc. Every method here binds it.
    CONTEXT = "BMCRPC"

    def for_patient(dfn)
      in_context { DataMapper.referral_search.fetch_many(dfn.to_s) }
    end

    def find(ien)
      return nil if ien.nil?

      in_context { DataMapper.referral_detail.fetch_one(ien.to_s) }
    end

    def delete(ien, reason: nil)
      in_context { DataMapper.referral_delete.fetch_one(ien.to_s, reason) }
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
      in_context do
        next nil unless bmc_supported?

        DataMapper.bmc_patient_eligibility_status.fetch_one(dfn.to_s, *params)
      end
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

    # Bind BMCRPC for the duration of the block and restore the caller's
    # option afterward (a no-op round-trip-wise when BMCRPC is already bound).
    # Every wire-reaching path below goes through here, the capability probe
    # inside the block so it is answered under the same option as the call.
    def in_context(&block)
      ContextScope.scoped(RpmsRpc.client, CONTEXT, &block)
    end

    def bmc_supported?
      RpmsRpc.client.supports?(:bmc_referral_workflow)
    end

    def bmc_many(mapping_name, *params)
      in_context do
        next [] unless bmc_supported?

        DataMapper[mapping_name].fetch_many(*params.map(&:to_s))
      end
    end

    def bmc_text(mapping_name, *params)
      in_context do
        next nil unless bmc_supported?

        DataMapper[mapping_name].fetch_text(*params.map(&:to_s))
      end
    end

    def bmc_scalar_result(mapping_name, *params)
      in_context do
        next unsupported_result unless bmc_supported?

        raw = DataMapper[mapping_name].fetch_scalar(*params.map(&:to_s))
        result_from_raw(raw)
      end
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
