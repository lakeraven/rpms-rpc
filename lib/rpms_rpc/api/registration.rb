# frozen_string_literal: true

require_relative "../mappings"
require_relative "ddr_fileman"

module RpmsRpc
  # Composed patient registration: VAFC VOA ADD PATIENT creates the VistA
  # PATIENT (#2) half; the DDR FileMan family completes the IHS half —
  # file #9000001 (IHS PATIENT, ^AUPNPAT), the HRN, and the tribal /
  # community / classification / eligibility fields. This replaces a
  # removed placeholder wire name that never had a server implementation
  # anywhere (docs/RPC_COVERAGE.md provenance notes).
  #
  # Flow (each step's wire contract cited in the method comments):
  #
  #   1. VAFC VOA ADD PATIENT  → PATIENT (#2) record, returns DFN
  #                              (ADD^VAFCPTAD — VAFCPTAD.m:4-147)
  #   2. DDR LOCK/UNLOCK NODE  → lock ^AUPNPAT(DFN) for the completion writes
  #   3. DDR LISTER            → HRN uniqueness pre-check on the "D"
  #                              cross-reference ^AUPNPAT("D",HRN,DFN)
  #                              (AG71A1.m:136-138)
  #   4. DDR GETS ENTRY DATA   → does ^AUPNPAT(DFN) already exist?
  #                              (idempotent re-run support)
  #   5. DDR FILER (x2)        → UPDATE^DIE files the #9000001 stub (.01 at
  #                              the DINUM IEN = DFN — creation convention
  #                              AUPNLK2.m:57), then the HRN into the 41
  #                              multiple + the optional IHS fields against
  #                              "DFN," (the live-proven two-pass sequence,
  #                              rpms-ops docs/REGISTRATION_RPC_CONTRACTS.md §6)
  #   6. unlock ^AUPNPAT(DFN)  → always, once locked
  #
  # Designed for idempotent re-run after a partial failure: VOA returns the
  # existing DFN for a known ICN (VAFCPTAD.m:55), the existence probe skips
  # the stub pass when ^AUPNPAT(DFN) is already there, and an already-filed
  # HRN row is skipped rather than re-added.
  module Registration
    extend self

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
    #   hrn:                health record number to file (with location_ien:)
    #   location_ien:       facility IEN for the 41 multiple's DINUM entry
    #   tribe:/classification:/eligibility_status:/community:
    #                       optional #9000001 completion values (see above)
    #   extra_fields:       [{ field:, value: }] escape hatch for additional
    #                       #9000001 top-level fields
    #
    # Returns:
    #   { success: true, dfn:, created: }               — registered (created:
    #     false = idempotent re-run against an existing #9000001 record)
    #   { success: false, error: Symbol, message: }     — rejected; error is
    #     :voa_rejected / :duplicate_identity / :lock_failed / :hrn_taken /
    #     :filer_rejected
    #   nil                                             — no broker response
    def register(attrs)
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
    # :lock_failed / :filer_rejected), or nil (no broker response).
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

    # Steps 3-5 against an already-locked ^AUPNPAT(DFN).
    def complete_ihs_registration(attrs, dfn)
      hrn = attrs[:hrn]&.to_s
      hrn_filed = false

      if hrn && !hrn.empty?
        listing = hrn_listing(hrn)
        return nil unless listing
        taken, hrn_filed = hrn_status(listing, hrn, dfn)
        return { success: false, error: :hrn_taken,
                 message: "HRN #{hrn} is already assigned to another patient" } if taken
      end

      exists = ihs_record_exists?(dfn)
      return nil if exists.nil?

      # Two FILER passes, mirroring the live-proven round trip (rpms-ops
      # docs/REGISTRATION_RPC_CONTRACTS.md §6): first the #9000001 stub at
      # the DINUM IEN, then the HRN subentry + completion fields against
      # the now-real "DFN," IENS.
      unless exists
        stub = DdrFileman.filer(mode: "ADD",
          rows: [ { file: PATIENT_FILE, field: ".01", iens: "+1,", value: dfn } ],
          iens: { 1 => dfn })
        failure = filer_failure(stub)
        return failure unless failure == :ok
      end

      rows, pins = completion_rows(attrs, dfn, hrn_filed: hrn_filed)
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

    # LIST^DIC over the whole-file "D" cross-reference
    # ^AUPNPAT("D",HRN,DFN) (AG71A1.m:136-138). PART narrows to entries
    # whose HRN starts with ours; rows come back IEN-first.
    def hrn_listing(hrn)
      DdrFileman.lister(file: PATIENT_FILE, max: "*", part: hrn, xref: "D")
    end

    # → [taken_by_other_patient, already_filed_for_this_dfn]
    # PART matching is prefix matching, so a row only counts as a conflict
    # when its value piece is absent (can't disprove) or exactly ours.
    def hrn_status(listing, hrn, dfn)
      taken = false
      filed = false
      listing[:entries].each do |entry|
        value = entry[:pieces]&.first
        exact = value.nil? || value.to_s.casecmp?(hrn)
        next unless exact
        if entry[:ien].to_i == dfn
          filed = true
        else
          taken = true
        end
      end
      [ taken, filed ]
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
    # UPDATE^DIE/FILE^DIE with no "E" flag (DDR3.m:15,18).
    def completion_rows(attrs, dfn, hrn_filed:)
      rows = []
      pins = {}

      hrn = attrs[:hrn]&.to_s
      if hrn && !hrn.empty? && !hrn_filed
        location = attrs[:location_ien].to_s
        raise ArgumentError, "registration location_ien is required to file an HRN" if location.empty?
        sub_iens = "+1,#{dfn},"
        # 41-multiple entry DINUM'd to the facility IEN (AGACT.m:10 edits at
        # DA=DUZ(2); pinned here via DDRIENS — FILEC^DDR3: DDR3.m:12-13);
        # .01 facility pointer (AG1.m:53), .02 HRN (AG1.m:54, AGEDNAME.m:63).
        rows << { file: HRN_SUBFILE, field: HRN_LOCATION_FIELD, iens: sub_iens, value: location }
        rows << { file: HRN_SUBFILE, field: HRN_FIELD, iens: sub_iens, value: hrn }
        pins[1] = location
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
  end
end
