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
    # See RpmsRpc::Registration.register for the attrs contract and the
    # per-step wire citations. Returns
    #   { success: true, dfn:, created: }           on success,
    #   { success: false, error: Symbol, message: } on rejection
    #     (:voa_rejected / :duplicate_identity / :lock_failed / :hrn_taken /
    #      :filer_rejected — message carries the M-side text), or
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

    # Patient telecom (FHIR Patient.telecom source) — home / work / cell
    # phone + email, read via the registered generic FileMan read
    # (DDR GETS ENTRY DATA — GETSC^DDR2: DDR2.m:17-43) against PATIENT
    # (#2) fields .131 / .132 / .134 / .133. Piece↔field identity for the
    # ^DPT(DFN,.13) node is cited from three independent corpus readers:
    #   piece 1 = .131 residence phone, piece 2 = .132 work phone,
    #   piece 3 = .133 email, piece 4 = .134 cellular
    #   (PTINFO1^BEHOPTCX: BEHOPTCX.m:34-41 — header
    #    "Phone(Res)^Phone(Work)^Phone(Cell)^Email" built from pieces
    #    1,2,4,3; DGRRPSAM.m:84-88 home=1/work=2; BQIPLADR.m:76).
    #
    # Why DDR and not a purpose-built RPC: the full corpus×registry sweep
    # of ^DPT(*,.13) readers found NO registered purpose-built RPC that
    # returns the phone as a structured patient read —
    #   BEHOPTCX PTINFO  — 20-piece identity bundle, no .13 data
    #                      (PTINFO^BEHOPTCX: BEHOPTCX.m:7-31)
    #   BEHOPTCX PTINFO1 — has exactly these fields but is NOT in the
    #                      #8994 registry (.broker_dumps_8994_20260607.txt
    #                      has PTINFO/PTINQ/LAST/... only)
    #   BEHOPTCX PTINQ   — report text, not structured
    #   DGRR GET PATIENT SERVICES DATA — home+work only, XML envelope
    #                      (DGRRPSAM.m:35-37), no cellular
    #   VEN ASQ GET DATA — home phone only, "|"-delimited ASQ projection
    #                      (DATA^VENPCCQ: VENPCCQ.m:180-213)
    #   BQI MAIL MERGE LIST — home/work in iCare BMX mail-merge format,
    #                      executes ^APCLVSTS print templates (BQIPLADR.m)
    #   BSDX WAITLIST    — waitlist rows, not a patient read (BSDX36.m:42)
    # The cellular phone (.134) in particular is served by NO purpose-built
    # registered RPC. DDR GETS ENTRY DATA is registered, already driven by
    # this gem (RpmsRpc::Registration), and returns all four structured.
    #
    # Returns { dfn:, phone_home:, phone_work:, phone_cell:, email: }
    # (missing values nil), or nil when the broker gives no response /
    # FileMan errors, so callers can distinguish "no phone on file" from
    # "unreachable".
    def contact(dfn)
      return nil if dfn.nil? || dfn.to_i <= 0

      reply = DdrFileman.gets_entry(file: "2", iens: "#{dfn.to_i},",
                                    fields: ".131;.132;.134;.133", flags: "IE")
      return nil if reply.nil? || reply[:error]

      fields = reply[:fields]
      {
        dfn:        dfn.to_i,
        phone_home: external(fields, ".131"),
        phone_work: external(fields, ".132"),
        phone_cell: external(fields, ".134"),
        email:      external(fields, ".133")
      }
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

    private

    # External (display) value of one field from a DdrFileman.gets_entry
    # reply; empty-on-file → nil.
    def external(fields, field_number)
      value = fields[field_number] && fields[field_number][:external]
      value.nil? || value.empty? ? nil : value
    end
  end
end
