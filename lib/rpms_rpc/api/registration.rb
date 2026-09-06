# frozen_string_literal: true

require_relative "../mappings"
require_relative "ddr_fileman"
require_relative "agg"

module RpmsRpc
  # Patient registration with two lineages, selected per broker at call time
  # (both replace a removed placeholder wire name that never had a server
  # implementation anywhere — docs/RPC_COVERAGE.md provenance notes):
  #
  #   * DELEGATION (RPMS with the AG package) — when Agg.available?, register
  #     by calling AGG ADD NEW PATIENT / AGG UPDATE PATIENT (RpmsRpc::Agg).
  #     The AG capsule owns demographics filing into PATIENT (#2) and IHS
  #     PATIENT (#9000001), the 41-multiple HRN, HL7/MPI staging into
  #     ^XTMP("AGHL7"), the ^AGPATCH register stamp, and the edit-check
  #     battery — so delegation INHERITS that logic instead of drifting from
  #     it. (Verdict "delegate": rpms-rpc#214, capture-verified.)
  #
  #   * COMPOSITION (civilian / stock VistA — no AG package) — the
  #     lineage-portable floor: VAFC VOA ADD PATIENT creates the PATIENT (#2)
  #     record, then the DDR FileMan family completes the IHS half (#9000001,
  #     the HRN 41-multiple, tribe / community / classification / eligibility).
  #     This replaces the retired "BHDPTRPC REGISTER" placeholder wire name,
  #     which never had a server implementation anywhere (docs/RPC_COVERAGE.md,
  #     "BHDPTRPC provenance").
  #
  # Composition flow (each step's wire contract cited in the method comments):
  #
  #   1. VAFC VOA ADD PATIENT  → PATIENT (#2) record, returns DFN
  #                              (ADD^VAFCPTAD — VAFCPTAD.m:4-147)
  #   2. DDR LOCK/UNLOCK NODE  → lock ^AUPNPAT(DFN) for the completion writes
  #   3. DDR GETS ENTRY DATA   → does ^AUPNPAT(DFN) already exist?
  #                              (idempotent re-run support)
  #   4. DDR FILER (x2)        → UPDATE^DIE files the #9000001 stub (.01 at
  #                              the DINUM IEN = DFN — creation convention
  #                              AUPNLK2.m:57), then the HRN into the 41
  #                              multiple + the optional IHS fields against
  #                              "DFN," (the live-proven two-pass sequence,
  #                              rpms-ops docs/REGISTRATION_RPC_CONTRACTS.md §6)
  #   5. unlock ^AUPNPAT(DFN)  → always, once locked
  #
  # Designed for idempotent re-run after a partial failure: VOA returns the
  # existing DFN for a known ICN (VAFCPTAD.m:55) and the existence probe skips
  # the stub + HRN pass when ^AUPNPAT(DFN) is already there.
  #
  # ## HRN handling (rpms-rpc#214)
  #
  # The client MUST NOT assign or enforce HRNs — HRN integrity is server
  # business logic. Two modes, selected by `Registration.hrn_mode`:
  #
  #   * :derive_from_dfn (DEFAULT, greenfield) — HRN := DFN. FileMan's IEN
  #     allocation IS the server-side atomic assigner, so the HRN is unique by
  #     construction with zero client logic and no race: create the patient,
  #     then file the returned DFN into the facility HRN field. (The DD input
  #     transform accepts 1-9 numeric digits — live-verified.)
  #
  #   * :clerk_supplied (legacy) — file the caller-supplied HRN as a plain
  #     passthrough. NO client-side uniqueness is performed here. A proper
  #     server-held claim (DDR LOCK -> all-holders D-xref walk -> DDR FILER ->
  #     unlock, all in one broker session so the M lock spans the sequence) is
  #     documented follow-up work (#214), not this PR — this is the seam.
  #
  # There is deliberately NO client-side HRN uniqueness/validation in either
  # mode (the PR #212 lineage's D-xref pre-check has been removed as
  # deprecated-by-design per #214).
  module Registration
    extend self

    # HRN assignment mode — see the module doc / rpms-rpc#214.
    HRN_MODE_DERIVE = :derive_from_dfn # greenfield default: HRN := DFN
    HRN_MODE_CLERK  = :clerk_supplied  # legacy: caller-supplied passthrough

    @hrn_mode = HRN_MODE_DERIVE

    # Site-selectable HRN mode (default :derive_from_dfn). Module-level state
    # via `extend self`, so `Registration.hrn_mode = :clerk_supplied`.
    attr_accessor :hrn_mode

    # IHS PATIENT file (#9000001, ^AUPNPAT). Created against the PATIENT
    # (#2) DFN with DINUM=DFN / DLAYGO=9000001 (AUPNLK2.m:57); AG pairs
    # ^AUPNPAT(RECNO) with ^DPT(RECNO) 1:1 (AG71A1.m:138).
    PATIENT_FILE = "9000001"

    # HEALTH RECORD multiple (subfile #9000001.41 — node header
    # "^9000001.41IP^^", AG1.m:59). Entries are DINUM'd to the facility:
    # AG edits use DA=DUZ(2) (AGACT.m:10; AG1.m:67); .01 is the facility
    # pointer (filed via top-level 4101 with backtick-IEN — AG1.m:53) and
    # .02 is the HRN/chart number (AG1.m:54,70; read back from
    # $P(^AUPNPAT(DFN,41,site,0),U,2) — AGEDNAME.m:63).
    HRN_SUBFILE = "9000001.41"
    HRN_LOCATION_FIELD = ".01"
    HRN_FIELD = ".02"

    # #9000001 completion fields. AUPNPAT field numbers are four-digit
    # (node 11 pieces) — real AG DR strings write them that way
    # (DR="1109////NONE;1110////NONE", AG2.m:19):
    #   1108 TRIBE OF MEMBERSHIP        (AGED2.m:385; pointer to ^AUTTTRI —
    #                                    read at $P(^AUPNPAT(DFN,11),U,8),
    #                                    AG2.m:16-19)
    #   1111 CLASSIFICATION/BENEFICIARY (AGED2.m:384; pointer to ^AUTTBEN —
    #                                    $P(^(11),U,11), AG2.m:31)
    #   1112 ELIGIBILITY STATUS         (AGED1.m:347; $P(^AUPNPAT(DFN,11),U,12),
    #                                    AG0.m:48; set of codes I/D/C/P per
    #                                    the live DD)
    #   1118 CURRENT COMMUNITY          (AGED1.m:354; free text per the live DD)
    # DDR FILER files INTERNAL-format values — UPDATE^DIE/FILE^DIE run with
    # no "E" flag (DDR3.m:15,18) — so callers pass pointer IENs (e.g. the
    # ^AUTTTRI IEN for tribe) and internal set codes verbatim; nothing is
    # derived or hardcoded here. Field definitions confirmed against the
    # live bcer-9.0-ydb DD in rpms-ops docs/REGISTRATION_RPC_CONTRACTS.md §5.
    FIELD_TRIBE = "1108"
    FIELD_CLASSIFICATION = "1111"
    FIELD_ELIGIBILITY = "1112"
    FIELD_COMMUNITY = "1118"

    OPTIONAL_FIELD_MAP = {
      tribe: FIELD_TRIBE,
      classification: FIELD_CLASSIFICATION,
      eligibility_status: FIELD_ELIGIBILITY,
      community: FIELD_COMMUNITY
    }.freeze

    # AG registration window used for delegation (file 9009068.3 — the
    # minimal demographics set; see RpmsRpc::Agg).
    AGG_WINDOW = Agg::DEFAULT_WINDOW

    # attrs (FileMan-external values unless noted — every VOA element runs
    # through CHK^DIE server-side, e.g. VAFCPTAD.m:41,64,70):
    #
    #   name:               "LAST,FIRST MIDDLE SUFFIX" (split at the first
    #                       comma), or name_last:/name_first:/name_middle:/
    #                       name_suffix: pieces
    #   dob:                Date/Time (formatted MM/DD/YYYY) or external string
    #   sex:                external SEX value ("F"/"M"/...)
    #   ssn:                9 digits, or nil/"" for the pseudo-SSN path
    #                       (VAFCPTAD.m:75-83)
    #   station_number:     the receiving station's number — VAFCPTAD requires
    #                       PRFCLTY == $$SITE^VASITE station (VAFCPTAD.m:40)
    #   full_icn:           "ICNVchecksum" (must contain "V", VAFCPTAD.m:45-46)
    #   type:               PATIENT #2 TYPE (#391) external value
    #   veteran:            "Y"/"N" (VAFCPTAD.m:105 keeps the first character)
    #   service_connected:  "YES"/"NO"
    #   pob_city:/pob_state:/mothers_maiden_name:  optional (VAFCPTAD.m:21-24)
    #   hrn:                caller-supplied HRN — used ONLY in the
    #                       :clerk_supplied legacy mode (see hrn_mode); the
    #                       greenfield default derives HRN := DFN and ignores
    #                       this. Never client-validated for uniqueness (#214).
    #   location_ien:       facility IEN for the 41 multiple's DINUM entry
    #                       (composition path — required to file an HRN)
    #   tribe:/classification:/eligibility_status:/community:
    #                       optional #9000001 completion values (see above)
    #   extra_fields:       [{ field:, value: }] escape hatch for additional
    #                       #9000001 top-level fields
    #
    # Returns:
    #   { success: true, dfn:, created: }               — registered (created:
    #     false = idempotent re-run against an existing #9000001 record)
    #   { success: false, error: Symbol, message: }     — rejected; error is
    #     :voa_rejected / :duplicate_identity / :lock_failed / :filer_rejected
    #     (composition) or :agg_rejected / :hrn_file_failed (delegation)
    #   nil                                             — no broker response
    #
    # Delegates to the AG capsule when it is installed on this broker
    # (Agg.available?), else composes VOA + DDR. Same result contract either
    # way, so engine code is lineage-agnostic.
    def register(attrs)
      if Agg.available?
        register_via_agg(attrs)
      else
        register_via_composition(attrs)
      end
    end

    # DELEGATION path — the AG capsule (RPMS with AG). Create via AGG ADD NEW
    # PATIENT, then file the HRN per hrn_mode. Prefer a short broker session
    # per registration (AG routines leak locals into long sessions — see Agg).
    def register_via_agg(attrs)
      clerk = (hrn_mode == HRN_MODE_CLERK)
      params = agg_add_params(attrs)
      # Legacy clerk-supplied HRN rides the create call (the capsule files it
      # into the 41-multiple). Greenfield sends no HRN — it is set to the DFN
      # afterward, below.
      params["AGGPTHRN"] = attrs[:hrn].to_s if clerk && present?(attrs[:hrn])

      created = Agg.add_patient(window: AGG_WINDOW, params: params)
      return created unless created && created[:success]

      dfn = created[:dfn]
      unless clerk
        # Greenfield: HRN := DFN. FileMan's IEN allocation already assigned a
        # unique DFN; echo it into the HRN field via the delegation update
        # path. No client-side uniqueness — unique by construction (#214).
        updated = Agg.update_patient(window: AGG_WINDOW, dfn: dfn, params: { "AGGPTHRN" => dfn.to_s })
        unless updated && updated[:success]
          return { success: false, error: :hrn_file_failed, dfn: dfn,
                   message: updated&.dig(:message).to_s }
        end
      end

      { success: true, dfn: dfn, created: true }
    end

    # COMPOSITION path — the lineage-portable floor (civilian / stock VistA,
    # no AG package).
    def register_via_composition(attrs)
      voa = DataMapper.voa_add_patient.fetch_one(voa_param(attrs))
      return nil unless voa
      return voa_failure(voa) unless voa[:status] == 1

      dfn = voa[:dfn_or_error].to_i
      node = "^AUPNPAT(#{dfn})"
      unless DdrFileman.lock(node: node)
        return { success: false, error: :lock_failed,
                 message: "could not lock #{node}" }
      end

      begin
        complete_ihs_registration(attrs, dfn)
      ensure
        DdrFileman.unlock(node: node)
      end
    end

    # Patient update — the composed edit path, replacing the removed
    # placeholder update wire name (docs/RPC_COVERAGE.md provenance
    # notes). The VA edit routine (EDIT^VAFCPTED — classic ^DIE filing
    # under L +^DPT(DFN):60, returns no output; contract in rpms-ops
    # docs/REGISTRATION_RPC_CONTRACTS.md §1) has NO ^XWB(8994)
    # registration on any observed target (staging file-8994 dump
    # 2026-06-07; live registry read 2026-09-02), so edits run through the
    # registered DDR FILER instead: FILE^DIE gives the same input
    # transform / cross-reference behavior (FILEC^DDR3: DDR3.m:16-18),
    # under the same ^DPT(DFN) lock VAFCPTED takes.
    #
    #   patient_fields: { "field#" => value } edits to PATIENT (#2)
    #   ihs_fields:     { "field#" => value } edits to IHS PATIENT (#9000001)
    #
    # Values are FileMan-INTERNAL (the filer runs with no "E" flag —
    # DDR3.m:15,18). Returns { success: true, dfn: },
    # { success: false, error:, message: } (:invalid_dfn / :no_fields /
    # :lock_failed / :filer_rejected), or nil (no broker response during
    # the filer step). NB: lock-step broker silence surfaces as
    # :lock_failed, not nil — DDR LOCK/UNLOCK NODE's reply grammar makes
    # no-response and lock-timeout indistinguishable (DdrFileman.lock
    # returns false for both); treat :lock_failed as retryable.
    def update(dfn, patient_fields: {}, ihs_fields: {})
      dfn = dfn.to_i
      return { success: false, error: :invalid_dfn, message: "a positive DFN is required" } if dfn <= 0

      rows =
        patient_fields.map { |field, value| { file: "2", field: field.to_s, iens: "#{dfn},", value: value.to_s } } +
        ihs_fields.map { |field, value| { file: PATIENT_FILE, field: field.to_s, iens: "#{dfn},", value: value.to_s } }
      return { success: false, error: :no_fields, message: "no fields to update" } if rows.empty?

      node = "^DPT(#{dfn})"
      unless DdrFileman.lock(node: node)
        return { success: false, error: :lock_failed, message: "could not lock #{node}" }
      end

      begin
        filed = DdrFileman.filer(mode: "EDIT", rows: rows)
        failure = filer_failure(filed)
        failure == :ok ? { success: true, dfn: dfn } : failure
      ensure
        DdrFileman.unlock(node: node)
      end
    end

    # Completion writes against an already-locked ^AUPNPAT(DFN).
    def complete_ihs_registration(attrs, dfn)
      exists = ihs_record_exists?(dfn)
      return nil if exists.nil?

      # Two FILER passes, mirroring the live-proven round trip (rpms-ops
      # docs/REGISTRATION_RPC_CONTRACTS.md §6): first the #9000001 stub at
      # the DINUM IEN, then the HRN subentry + completion fields against
      # the now-real "DFN," IENS. On an idempotent re-run (record already
      # present) the stub and the 41-multiple HRN row are skipped — the HRN
      # was filed on the original create.
      unless exists
        stub = DdrFileman.filer(mode: "ADD",
          rows: [ { file: PATIENT_FILE, field: ".01", iens: "+1,", value: dfn } ],
          iens: { 1 => dfn })
        failure = filer_failure(stub)
        return failure unless failure == :ok
      end

      rows, pins = completion_rows(attrs, dfn, hrn_new: !exists)
      return { success: true, dfn: dfn, created: !exists } if rows.empty?

      filed = DdrFileman.filer(mode: "ADD", rows: rows, iens: pins)
      failure = filer_failure(filed)
      return failure unless failure == :ok

      { success: true, dfn: dfn, created: !exists }
    end

    # Build the VOA ADD PATIENT list param — named subscripts per
    # ADD^VAFCPTAD's documented elements (VAFCPTAD.m:10-25). Public so
    # tests/mocks can seed against the exact payload the RPC receives.
    # Raises ArgumentError (naming the attribute, never echoing the value —
    # these are demographics/PHI) when a required element is missing or a
    # name piece contains the "^" piece separator.
    def voa_param(attrs)
      %i[station_number sex dob type veteran service_connected full_icn].each do |key|
        raise ArgumentError, "registration #{key} is required" if attrs[key].to_s.strip.empty?
      end

      param = {
        "PRFCLTY" => attrs[:station_number].to_s,
        "NAME" => name_pieces(attrs),
        "GENDER" => attrs[:sex].to_s.strip.upcase,
        "DOB" => external_date(attrs[:dob]),
        # SSN must be PRESENT but may be null — null files a pseudo-SSN
        # (VAFCPTAD.m:75-83).
        "SSN" => attrs[:ssn].to_s.delete("-"),
        "SRVCNCTD" => attrs[:service_connected].to_s,
        "TYPE" => attrs[:type].to_s,
        "VET" => attrs[:veteran].to_s,
        "FULLICN" => attrs[:full_icn].to_s
      }
      param["POBCTY"] = attrs[:pob_city].to_s if attrs[:pob_city]
      param["POBST"] = attrs[:pob_state].to_s if attrs[:pob_state]
      param["MMN"] = attrs[:mothers_maiden_name].to_s if attrs[:mothers_maiden_name]
      param
    end

    private

    def voa_failure(voa)
      message = voa[:dfn_or_error].to_s
      # ADD^VAFCPTAD has no dedicated duplicate error (FILE^DICN runs with
      # DIC(0)="FLZ" — no lookup screening, VAFCPTAD.m:130); classification
      # here is a best-effort match on the -1 text. A known ICN is NOT an
      # error — it returns "1^DFN" (VAFCPTAD.m:55).
      error = message.match?(/duplicat|already (exist|register)/i) ? :duplicate_identity : :voa_rejected
      { success: false, error: error, message: message }
    end

    # NAME crosses the wire as LAST^FIRST^MIDDLE^SUFFIX; the server
    # reassembles "LAST,FIRST MIDDLE SUFFIX" (VAFCPTAD.m:57-63), so a
    # "LAST,REST" string split at the first comma round-trips identically
    # with REST riding the FIRST piece.
    def name_pieces(attrs)
      pieces =
        if attrs[:name_last]
          [ attrs[:name_last], attrs[:name_first], attrs[:name_middle], attrs[:name_suffix] ]
            .map { |p| p.to_s.strip.upcase }
        else
          name = attrs[:name].to_s.strip.upcase
          raise ArgumentError, "registration name is required" if name.empty?
          last, rest = name.split(",", 2)
          [ last.to_s.strip, rest.to_s.strip ]
        end
      if pieces.any? { |p| p.include?("^") }
        raise ArgumentError, "registration name must not contain '^'"
      end
      pieces.join("^").sub(/\^+\z/, "")
    end

    # VOA elements are FileMan-external (CHK^DIE per element —
    # e.g. DOB at VAFCPTAD.m:70), so dates go over as MM/DD/YYYY.
    def external_date(value)
      return value.strftime("%m/%d/%Y") if value.is_a?(Date) || value.is_a?(Time)
      value.to_s
    end

    # Existence probe for the idempotent re-run path: GETS^DIQ on the .01.
    # A missing record surfaces as the "[ERROR]" marker (DDR2.m:61).
    def ihs_record_exists?(dfn)
      probe = DdrFileman.gets_entry(file: PATIENT_FILE, iens: "#{dfn},", fields: ".01")
      return nil unless probe
      !probe[:error] && !probe[:fields].empty?
    end

    def filer_failure(filed)
      return nil if filed.nil?
      return :ok if filed[:success]
      { success: false, error: :filer_rejected, message: filed[:errors].join("; ") }
    end

    # Build the completion-pass DDR FILER rows against the existing #9000001
    # record ("DFN," IENS). All values are FileMan-INTERNAL — the filer runs
    # UPDATE^DIE/FILE^DIE with no "E" flag (DDR3.m:15,18). The HRN 41-multiple
    # row is filed only for a newly created record (hrn_new); a re-run against
    # an existing record leaves the already-filed HRN untouched.
    def completion_rows(attrs, dfn, hrn_new:)
      rows = []
      pins = {}

      hrn = effective_hrn(attrs, dfn)
      location = attrs[:location_ien].to_s
      if hrn && !hrn.empty? && hrn_new
        # The 41-multiple entry is keyed to a facility, so it can only be
        # filed with a location_ien. A :clerk_supplied caller who provides an
        # HRN but no facility is a misconfiguration → raise. Greenfield
        # (HRN := DFN, auto) with no facility simply defers the HRN row —
        # the patient is still created; the HRN can be filed once a facility
        # is known.
        if location.empty?
          raise ArgumentError, "registration location_ien is required to file an HRN" if hrn_mode == HRN_MODE_CLERK
        else
          sub_iens = "+1,#{dfn},"
          # 41-multiple entry DINUM'd to the facility IEN (AGACT.m:10 edits at
          # DA=DUZ(2); pinned here via DDRIENS — FILEC^DDR3: DDR3.m:12-13);
          # .01 facility pointer (AG1.m:53), .02 HRN (AG1.m:54, AGEDNAME.m:63).
          rows << { file: HRN_SUBFILE, field: HRN_LOCATION_FIELD, iens: sub_iens, value: location }
          rows << { file: HRN_SUBFILE, field: HRN_FIELD, iens: sub_iens, value: hrn }
          pins[1] = location
        end
      end

      OPTIONAL_FIELD_MAP.each do |key, field|
        value = attrs[key]
        next if value.nil? || value.to_s.empty?
        rows << { file: PATIENT_FILE, field: field, iens: "#{dfn},", value: value.to_s }
      end

      Array(attrs[:extra_fields]).each do |extra|
        rows << { file: PATIENT_FILE, field: extra[:field].to_s, iens: "#{dfn},",
                  value: extra[:value].to_s }
      end

      [ rows, pins ]
    end

    # The HRN to file, per hrn_mode (#214). Greenfield derives it from the
    # server-assigned DFN (unique by construction); legacy passes the
    # caller-supplied value straight through. NO client-side uniqueness in
    # either mode.
    def effective_hrn(attrs, dfn)
      if hrn_mode == HRN_MODE_CLERK
        attrs[:hrn]&.to_s
      else
        dfn.to_s
      end
    end

    # Demographics PARMS for AGG ADD NEW PATIENT (Mini Registration window).
    # Values are FileMan-external — AGGPTSEX is the coded set value
    # ("MALE"/"FEMALE"), dates MM/DD/YYYY. Absent attributes are omitted
    # (Agg.encode_parms drops nils). HRN is handled by the caller per mode.
    def agg_add_params(attrs)
      last, first, middle, suffix = name_parts(attrs)
      {
        "AGGPTLNM" => last,
        "AGGPTFNM" => first,
        "AGGPTMNM" => blank_to_nil(middle),
        "AGGPTSFX" => blank_to_nil(suffix),
        "AGGPTDOB" => blank_to_nil(external_date(attrs[:dob])),
        "AGGPTSEX" => agg_sex(attrs[:sex]),
        "AGGPTSSN" => blank_to_nil(attrs[:ssn].to_s.delete("-"))
      }
    end

    # AGG name pieces as [last, first, middle, suffix] — same "^"-splitting
    # contract as name_pieces (raises on a "^" in any piece / a blank name).
    def name_parts(attrs)
      pieces = name_pieces(attrs).split("^", -1)
      [ pieces[0].to_s, pieces[1].to_s, pieces[2].to_s, pieces[3].to_s ]
    end

    # AGGPTSEX is the C-type window param coded MALE^M / FEMALE^F — the
    # client sends the external set value. Map the VOA-style "M"/"F" used
    # elsewhere in this module; pass any other value through uppercased.
    def agg_sex(sex)
      case sex.to_s.strip.upcase
      when "M", "MALE" then "MALE"
      when "F", "FEMALE" then "FEMALE"
      else blank_to_nil(sex.to_s.strip.upcase)
      end
    end

    def blank_to_nil(value)
      s = value.to_s
      s.empty? ? nil : s
    end

    def present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end
  end
end
