# frozen_string_literal: true

require_relative "registration"

module RpmsRpc
  # Symbolic API for patient data. Engine code calls these methods
  # instead of referencing DataMapper mappings directly.
  module Patient
    extend self

    def find(dfn)
      return nil if dfn.nil? || dfn.to_i <= 0

      attrs = DataMapper.patient_select.fetch_one(dfn.to_s, extras: { dfn: dfn.to_i })
      return nil unless attrs

      extended = DataMapper.patient_id_info.fetch_one(dfn.to_s)
      attrs.merge!(extended) if extended

      attrs
    end

    def search(name_pattern)
      DataMapper.patient_list.fetch_many(name_pattern.to_s, "1")
    end

    def find_by_ssn(ssn)
      return nil if ssn.nil? || ssn.to_s.empty?

      DataMapper.patient_ssn.fetch_one(ssn.to_s)
    end

    # Register a new patient — delegates to the composed
    # RpmsRpc::Registration flow: VAFC VOA ADD PATIENT (PATIENT #2 half,
    # ADD^VAFCPTAD) + the DDR FileMan family (IHS #9000001 half: HRN,
    # tribe/community/classification/eligibility). The former "BHDPTRPC
    # REGISTER" placeholder wire name is retired — it never had a server
    # implementation anywhere (docs/RPC_COVERAGE.md, "BHDPTRPC provenance").
    #
    # VALUE FORMAT — read before calling. The #9000001 completion values
    # (tribe/classification/eligibility_status/community) and any pointer field
    # are FileMan-INTERNAL: DDR FILER runs UPDATE^DIE/FILE^DIE with no "E" flag
    # (DDR3.m:15,18), so pass the raw pointer IEN (e.g. the ^AUTTTRI IEN for
    # tribe) and internal set codes verbatim — this layer derives nothing. The
    # VAFC VOA ADD elements, by contrast, are FileMan-EXTERNAL (each runs
    # through CHK^DIE server-side). service_connected/veteran are internal
    # "Y"/"N". See RpmsRpc::Registration.register for the full attrs contract
    # and the per-step wire citations.
    #
    # ONC SCOPE: this composed path is NOT part of any certification — it is
    # additive and alters no certified-module behavior. §170.315(a)(5)
    # demographics is certified via the AG/BPRM path, not this one; use this for
    # demo / eval / greenfield-exempt registration (see the KNOWN DIVERGENCES in
    # RpmsRpc::Registration: no HRN-uniqueness enforcement, no HL7 staging, no
    # AG procedural validation).
    #
    # Returns
    #   { success: true, dfn:, created: }           on success,
    #   { success: false, error: Symbol, message: } on rejection
    #     (:voa_rejected / :identity_mismatch / :lock_failed / :filer_rejected —
    #      message carries the M-side text; identity_mismatch = VOA resolved an
    #      existing ICN to a DIFFERENT person, caught before any write), or
    #   nil when the broker gives no response at all (infra failure) so
    #   callers can distinguish "rejected" from "unreachable".
    def register(attrs)
      Registration.register(attrs)
    end

    # Chart-banner projection per issue #60 contract:
    #
    #   { name:, dob:, sex:, mrn:, age:, allergy_flag:, ad_flag:, primary_provider: }
    #
    # Composed from three RPCs:
    #   - BEHOPTCX PTINFO         (name, sex, DOB raw, MRN, primary provider name)
    #   - BEHOPTPC GETBDP         (designated primary provider — overrides if present)
    #   - BEHOCACV CWAD           (Crises/Warnings/Allergies/Directives flags)
    #
    # Returns nil for invalid (nil / zero / negative) DFNs and for unknown DFNs
    # (no PTINFO and no GETBDP response).
    def brief_header(dfn)
      return nil if dfn.nil? || dfn.to_i <= 0
      return nil unless RpmsRpc.client.supports?(:patient_chart_banner)

      ptinfo = DataMapper.patient_ptinfo.fetch_one(dfn.to_s)
      bdp    = DataMapper.patient_designated_provider.fetch_one(dfn.to_s)
      return nil if ptinfo.nil? && bdp.nil?

      cwad = DataMapper.patient_cwad.fetch_scalar(dfn.to_s) || ""
      dob  = FilemanDateParser.parse_date(ptinfo && ptinfo[:dob_raw])
      provider = (bdp && bdp[:provider_name]) || (ptinfo && ptinfo[:primary_provider])

      {
        name:             ptinfo && ptinfo[:name],
        dob:              dob,
        sex:              ptinfo && ptinfo[:sex],
        mrn:              ptinfo && ptinfo[:mrn],
        age:              age_from(dob),
        allergy_flag:     cwad.to_s.include?("A"),
        ad_flag:          cwad.to_s.include?("D"),
        primary_provider: provider
      }
    rescue RpmsRpc::Client::RpcError => e
      # Only degrade to nil when the error signature indicates the RPC
      # itself is unavailable on this Broker (BHS package not installed,
      # OPTION lacks the RPC, etc.). Genuine M-runtime errors and
      # permission/authorization failures must propagate so they aren't
      # silently masked as "feature unavailable".
      raise unless e.message.match?(/<NOLINE>|Remote Procedure .* (?:doesn't exist|not found)/i)
      nil
    end

    # Compute integer years between dob and today. `today:` is a keyword arg
    # for testability — production callers omit it and get Date.today.
    # Default is `nil` (not `Date.today`) so the nil-DOB guard runs before
    # touching the Date constant, keeping the helper safe even if `Date`
    # hasn't been required by the caller.
    def age_from(dob, today: nil)
      return nil if dob.nil?
      today ||= Date.today
      years = today.year - dob.year
      years -= 1 if today.month < dob.month || (today.month == dob.month && today.day < dob.day)
      years
    end
  end
end
