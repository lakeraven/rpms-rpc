# frozen_string_literal: true

require_relative "../mappings"
require_relative "../context_scope"
require_relative "../rcis_wire"

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
  # RpmsRpc::Agg does for AGGRPC. A client that cannot scope contexts runs
  # as-is. A programmer-key session bypasses the check either way, so only a
  # non-programmer run is evidence of this bind.
  #
  # The BMC methods call their RPC unconditionally. A broker that does not
  # serve it raises Client::RpcNotAvailableError; one that serves it but not
  # to this user raises Client::RpcRefusedError (#363).
  module Referral
    extend self

    # The context option the BMC* RPCs are registered under — see the module
    # doc. Every method here binds it.
    CONTEXT = "BMCRPC"

    # STATUS OF REFERRAL (file 90001, field .15) code for a cancelled
    # referral: X, CLOSED-NOT COMPLETED. RCIS's own reports skip X as
    # "cancelled" (BMCRR121.m:39, BMCRR41.m:38).
    CANCELLED_STATUS = "X"

    # Every referral on file for one patient: BMC SEARCH REFERRAL, which is
    # SRCHREF^BMCRPC1(RSLT,PATIENT,REFPRVDR,STRTDATE,ENDDATE,RECNMBR,STATUS)
    # (BMCRPC1.m:9). All six formals are sent, because the routine reads
    # RECNMBR and REFPRVDR without $G (BMCRPC1.m:32,34) and a formal the
    # broker is not sent is undefined: a DFN-only frame died with LVUNDEF
    # RECNMBR at SRCHREF+23 (#210). The five after the patient mean "no filter":
    #   REFPRVDR ""  no referring-provider screen (BMCRPC1.m:34)
    #   STRTDATE ""  no start date (BMCRPC1.m:40)
    #   ENDDATE  ""  no end date (BMCRPC1.m:41)
    #   RECNMBR  ""  +"" is not > 0, so "*": every record (BMCRPC1.m:32)
    #   STATUS   ""  no status screen (BMCRPC1.m:25,35)
    SEARCH_NO_FILTERS = [ "", "", "", "", "" ].freeze

    def for_patient(dfn)
      in_context { DataMapper.referral_search.fetch_many(dfn.to_s, *SEARCH_NO_FILTERS) }
    end

    # One referral by RCIS REFERRAL (#90001) IEN, with its diagnoses and
    # notes named from the sections GTRFBYID^BMCRPC1 appends (#210).
    def find(ien)
      return nil if ien.nil?

      record = in_context { DataMapper.referral_detail.fetch_one(ien.to_s) }
      record && name_sections(record)
    end

    def add(*params)
      bmc_scalar_result(:bmc_add_referral, *params)
    end

    def update(ien, *params)
      bmc_scalar_result(:bmc_update_referral, ien, *params)
    end

    # The STANDARD IHS REFERRAL LETTER as text (PRINT^BMCRPC5, BMCRPC5.m:50-64).
    def print(ien, *params)
      bmc_text(:bmc_print_referral, ien.to_s, *params)
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

      in_context do
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

    # PROV^BMCRPC4 answers one node, "-1^All~IEN^NAME~...": the "All"
    # entry is a picker option, not a user, so it is dropped (#210).
    def users_providers(*params)
      RcisWire.records(bmc_text(:bmc_users_providers, *params)).filter_map do |rec|
        ien, name = rec.split("^", 2)
        { ien: ien, name: name } if ien.to_i.positive?
      end
    end

    # Active holders of the PROVIDER key, { duz:, name: } each (PROV^ORQPTQ2,
    # ORQPTQ2.m:95-101). PROV(Y) takes no parameter: one sent anyway is "more
    # actual than formal parameters" (#364).
    def providers
      bmc_many(:bmc_providers)
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

    # RCIS DIAGNOSIS (#90001.01) entry pieces, BMCRPC4.m:104-114.
    DIAGNOSIS_FIELDS = %i[ien icd_ien patient_dfn referral_ien type primary_secondary
                          narrative_ien icd_code narrative].freeze

    # Note sections by GETMEDHX tag (BMCRPC1.m:124-128): S (secondary
    # referral notes) is sent under B.
    NOTE_SECTIONS = { medical_history: "M", business_office: "B", case: "C" }.freeze

    def name_sections(record)
      sections = record.delete(:sections) || {}
      diagnoses = (sections["D"] || []).map { |pieces| DIAGNOSIS_FIELDS.zip(pieces).to_h }
      notes = NOTE_SECTIONS.transform_values do |tag|
        (sections[tag] || []).map { |pieces| note(pieces) }
      end
      record.merge(diagnoses: diagnoses, notes: notes)
    end

    # RFCMTIEN^CMDATE^REVIEWER^text, word-processing lines joined by "~"
    # (BMCRPC1.m:136-143).
    def note(pieces)
      ien, date, reviewer, *text = pieces
      { ien: ien, date: date, reviewer: reviewer, text: text.join("^").tr("~", "\n") }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    # Bind BMCRPC for the duration of the block and restore the caller's
    # option afterward (a no-op round-trip-wise when BMCRPC is already bound).
    # Every wire-reaching path below goes through here.
    def in_context(&block)
      ContextScope.scoped(RpmsRpc.client, CONTEXT, &block)
    end

    def bmc_many(mapping_name, *params)
      in_context { DataMapper[mapping_name].fetch_many(*params.map(&:to_s)) }
    end

    def bmc_text(mapping_name, *params)
      in_context { DataMapper[mapping_name].fetch_text(*params.map(&:to_s)) }
    end

    def bmc_scalar_result(mapping_name, *params)
      in_context do
        raw = DataMapper[mapping_name].fetch_scalar(*params.map(&:to_s))
        result_from_raw(raw)
      end
    end

    def result_from_raw(raw)
      rcis = RcisWire.result(raw)
      return rcis.merge(raw: raw) if rcis

      line = raw.to_s.strip
      return { success: false, raw: raw } if line.empty?

      success = line.start_with?("1") || line.match?(/\A[1-9]\d*\z/)
      message = line.sub(/\A[01]\^/, "").strip
      { success: success, message: message.empty? ? nil : message, raw: raw }
    end
  end
end
