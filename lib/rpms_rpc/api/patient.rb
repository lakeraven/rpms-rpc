# frozen_string_literal: true

require_relative "registration"
require_relative "../phi_sanitizer"

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

    # AGG LOOKUP PATIENTS — the IHS division-aware lookup (FND^AGGPTLKP).
    #
    # Prefer this over #search on a multi-divisional RPMS: stock
    # ORWPT LIST ALL has no division screen, so it returns patients from
    # every division to a user scoped to one.
    #
    #   all_divisions:    search beyond the caller's division (ALL)
    #   include_inactive: include patients inactive at the division (INAC)
    #   type:             search type code; "" searches all cross-references
    #
    # AGGPTLKP has NO result-limit parameter. A limit passed positionally
    # would land on ALL or INAC and silently widen the search instead of
    # narrowing it, so it is refused rather than accepted and ignored.
    #
    # SSN is masked on the wire to "XXX-XX-nnnn" when the caller lacks the
    # AGZVIEWSSN security key (AGGPTLKP.m:124). That is a redaction, not an
    # identifier — it is returned as ssn: nil with ssn_masked: true so a
    # caller cannot persist it as though it were an SSN.
    def lookup(text, type: "", all_divisions: false, include_inactive: false, **opts)
      if opts.key?(:limit)
        raise ArgumentError,
              "AGG LOOKUP PATIENTS has no result-limit parameter; a limit " \
              "passed positionally sets ALL or INAC and widens the search"
      end
      raise ArgumentError, "search text is required" if text.to_s.strip.empty?

      rows = fetch_lookup_rows(
        DataMapper.patient_lookup_agg,
        text.to_s,
        type.to_s,
        all_divisions ? "1" : "",
        include_inactive ? "1" : ""
      )

      rows.map { |row| normalize_lookup_row(row) }
    end

    def find_by_ssn(ssn)
      return nil if ssn.nil? || ssn.to_s.empty?

      DataMapper.patient_ssn.fetch_one(ssn.to_s)
    end

    # Register a new patient via RpmsRpc::Registration, which picks its
    # lineage per broker: DELEGATION to the IHS AG capsule (AGG ADD NEW
    # PATIENT / AGG UPDATE PATIENT) when it is installed, else COMPOSITION
    # from stock-VistA RPCs (VAFC VOA ADD PATIENT + the DDR FileMan family
    # for the IHS #9000001 half).
    #
    # See RpmsRpc::Registration.register for the attrs contract, the HRN
    # policy (Registration.hrn_mode), and the per-step wire citations. Returns
    #   { success: true, dfn:, created: }           on success,
    #   { success: false, error: Symbol, message: } on rejection
    #     (:voa_rejected / :duplicate_identity / :lock_failed /
    #      :filer_rejected for composition; :agg_rejected / :hrn_file_failed
    #      for delegation — message carries the M-side text), or
    #   nil when the broker gives no response at all (infra failure) so
    #   callers can distinguish "rejected" from "unreachable".
    def register(attrs)
      Registration.register(attrs)
    end

    # Update patient fields — delegates to the composed
    # RpmsRpc::Registration.update flow (DDR FILER / FILE^DIE under the
    # ^DPT(DFN) lock). See that method for the field contracts and return
    # shape.
    def update(dfn, patient_fields: {}, ihs_fields: {})
      Registration.update(dfn, patient_fields: patient_fields, ihs_fields: ihs_fields)
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
    # AGG LOOKUP PATIENTS is a GLOBAL ARRAY (return type 4) reply: FND^AGGPTLKP
    # sets DATA=$NA(^TMP("AGGPTLK",UID)) (AGGPTLKP.m:7), so the broker sends a
    # typed header followed by $C(30)-separated records, ending at $C(31).
    #
    # $C(30) IS the CIA EOD, so the default read_until_raw(EOD) stops at the
    # header row and every patient is lost — on the wire only; seeded tests
    # still pass, which is how this survived review. CiaClient reads to the
    # $C(31) sentinel in #call_rpc_global_array; RpmsRpc::Agg routes its AGG
    # RPCs the same way (Agg#call_array).
    LOOKUP_RECORD_SEP = "\x1e" # $C(30) — record separator (== CIA EOD)
    LOOKUP_ARRAY_END  = "\x1f" # $C(31) — end-of-array sentinel
    LOOKUP_ACK        = "\x00" # broker ack byte after the sequence echo

    def fetch_lookup_rows(mapping, *params)
      client = RpmsRpc.client
      raw = if client.respond_to?(:call_rpc_global_array)
        client.call_rpc_global_array(mapping.rpc_name, *params)
      else
        client.call_rpc(mapping.rpc_name, *params)
      end

      mapping.parse_many(decode_global_array(raw))
    end

    # Returns the record lines when the reply carries global-array framing, or
    # the payload untouched when it does not — a client without
    # #call_rpc_global_array answers with an ordinary newline-delimited body,
    # which parse_many splits itself.
    def decode_global_array(raw)
      # A client (or the mock) may already answer with line arrays; only a
      # String can carry the wire framing, and raw.to_s on an Array would hand
      # parse_many the inspect form.
      return raw unless raw.is_a?(String)

      body = raw.dup
      body = body.split(LOOKUP_ACK, 2).last.to_s if body.include?(LOOKUP_ACK)
      body = body.split(LOOKUP_ARRAY_END, 2).first.to_s
      return body unless body.include?(LOOKUP_RECORD_SEP)

      body.split(LOOKUP_RECORD_SEP).map { |row| row.force_encoding(Encoding::UTF_8) }
    end

    # Masked-SSN shape from AGGPTLKP.m:124 (LST) and :194 (LST2). LST2 omits
    # LST's SSN'="" guard, so a patient with no SSN comes back as the bare
    # prefix "XXX-XX-" with no digits — both forms are redactions.
    MASKED_SSN = /\AXXX-XX-\d*\z/

    def normalize_lookup_row(row)
      dfn = row[:dfn_raw].to_s.strip
      unless dfn.match?(/\A\d+\z/)
        raise Client::RpcError,
              "AGG LOOKUP PATIENTS returned a non-numeric DFN (#{PhiSanitizer.sanitize_message(dfn)}) " \
              "— an M error arriving as a data row, not a patient"
      end

      ssn = row[:ssn_raw].to_s.strip
      masked = ssn.match?(MASKED_SSN)

      {
        dfn: dfn.to_i,
        name: row[:name],
        hrn: row[:hrn],
        ssn: (masked || ssn.empty?) ? nil : ssn,
        ssn_masked: masked,
        dob: row[:dob],
        dod: row[:dod],
        sens_flag: row[:sens_flag],
        alias: row[:alias],
        inactive: row[:inactive_raw].to_s.strip.upcase == "Y",
        community: row[:community],
        mothers_maiden_name: row[:mothers_maiden_name]
      }
    end

    def age_from(dob, today: nil)
      return nil if dob.nil?
      today ||= Date.today
      years = today.year - dob.year
      years -= 1 if today.month < dob.month || (today.month == dob.month && today.day < dob.day)
      years
    end
  end
end
