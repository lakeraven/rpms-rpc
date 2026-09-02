# frozen_string_literal: true

require "date"
require_relative "../mappings"
require_relative "ddr_fileman"

module RpmsRpc
  # Composed patient registration: VAFC VOA ADD PATIENT creates the VistA
  # PATIENT (#2) half; the DDR FileMan family completes the IHS half —
  # file #9000001 (IHS PATIENT, ^AUPNPAT), the HRN, and the tribal /
  # community / classification / eligibility fields. This replaces the
  # retired "BHDPTRPC REGISTER" placeholder wire name, which never had a
  # server implementation anywhere (docs/RPC_COVERAGE.md, "BHDPTRPC
  # provenance").
  #
  # Flow (each step's wire contract cited in the method comments):
  #
  #   1. VAFC VOA ADD PATIENT  → PATIENT (#2) record, returns DFN
  #                              (ADD^VAFCPTAD — VAFCPTAD.m:4-147)
  #   2. IDENTITY GUARD        → ORWPT ID INFO on the resolved DFN; abort on a
  #                              name/DOB/sex mismatch (wrong-patient safety)
  #   3. DDR LOCK/UNLOCK NODE  → lock ^AUPNPAT(DFN) for the completion writes
  #   4. DDR GETS ENTRY DATA   → does ^AUPNPAT(DFN) already exist?
  #                              (idempotent re-run support)
  #   5. DDR FILER (x2)        → UPDATE^DIE files the #9000001 stub (.01/.02/.11
  #                              at the DINUM IEN = DFN — AUPNLK2.m:55-58), then
  #                              the HRN into the 41 multiple + the optional IHS
  #                              fields (rpms-ops docs/REGISTRATION_RPC_CONTRACTS.md §6)
  #   6. unlock ^AUPNPAT(DFN)  → always, once locked
  #
  # Idempotent re-run after a partial failure: VOA returns the existing DFN for
  # a known ICN (VAFCPTAD.m:55), the existence probe skips the stub pass when
  # ^AUPNPAT(DFN) is already there, and the 41-multiple HRN row is DINUM'd to
  # the facility IEN (AUPNLK2's .01 `S DINUM=X`), so UPDATE^DIE upserts it
  # rather than duplicating on a re-run.
  #
  # KNOWN DIVERGENCES from AG-native registration (this path files through the
  # generic DDR FileMan surface, NOT the AG package's ADD^AG* entry points, so
  # AG's procedural side effects do not run):
  #
  #   * NO HRN uniqueness enforcement. On file #9000001.41, field .02 (HEALTH
  #     RECORD NO.) has a format-only input transform and its "D" cross-reference
  #     is a plain SET index (`S ^AUPNPAT("D",$E(X,1,30),DA(1),DA)=""`) — neither
  #     rejects a duplicate (live DD, rpms-ydb-9.0 ^DD(9000001.41,.02), 2026-09-02).
  #     RPMS enforces chart-number uniqueness PROCEDURALLY inside the AG package,
  #     which is unreachable through DDR. This path will therefore FILE whatever
  #     HRN it is given; callers that need uniqueness must enforce it upstream
  #     (or wait for the Z-wrapper / AGHL7 decision — see below). The node lock
  #     in step 3 gives record-level write safety on THIS patient's ^AUPNPAT(DFN)
  #     entry; it does NOT and cannot make cross-patient HRN assignment atomic.
  #   * NO HL7 staging. AG-native registration stages an ADT message under
  #     ^XTMP("AGHL7") for the MPI/downstream feeds; ^XTMP is not a FileMan file,
  #     so DDR cannot write it and this path does not.
  #   * Field-level validation is FileMan transforms only (CHK^DIE per VOA
  #     element, then the #9000001 fields' own input transforms) — the AG2-class
  #     procedural invariants (e.g. inactive-tribe rejection) do NOT run.
  #
  # These divergences are acceptable for demo / eval / greenfield use; a future
  # AGHL7 Z-wrapper (staging the ADT event + running the AG procedural checks)
  # is the path to parity. This module is ADDITIVE — it alters no certified-module
  # behavior — and is NOT part of any ONC certification (see README, "ONC
  # scope"): §170.315(a)(5) demographics is certified via the AG/BPRM path, not
  # this one.
  module Registration
    extend self

    # IHS PATIENT file (#9000001, ^AUPNPAT). Created against the PATIENT
    # (#2) DFN with DINUM=DFN / DLAYGO=9000001 (AUPNLK2.m:55-57); AG pairs
    # ^AUPNPAT(RECNO) with ^DPT(RECNO) 1:1.
    PATIENT_FILE = "9000001"

    # #9000001 stub fields, filed at the DINUM IEN = DFN. AG's IHSPAT^AUPNLK2
    # files the stub as `.01` (via DINUM) PLUS `.02////`_DT_`;.11////`_DUZ
    # (AUPNLK2.m:57) — DATE ESTABLISHED (#.02, an FM date) and ESTABLISHING
    # USER (#.11, a pointer to NEW PERSON #200). Both are Required in the DD
    # (^DD(9000001,.02)=..."RDI"...; ^DD(9000001,.11)=..."RP200'I"...), so the
    # stub files them too rather than leaving a #9000001 record without its
    # provenance.
    STUB_NAME_FIELD = ".01"
    STUB_DATE_FIELD = ".02"
    STUB_USER_FIELD = ".11"

    # HEALTH RECORD multiple (subfile #9000001.41). The subentry is DINUM'd to
    # the facility: field .01 (HEALTH RECORD FAC) is
    # `HEALTH RECORD FAC^P9999999.06'Xa^AUTTLOC(^0;1^S DINUM=X` (live DD
    # ^DD(9000001.41,.01)) — so location_ien is a pointer into ^AUTTLOC
    # (#9999999.06, the IHS LOCATION file), NOT the VistA INSTITUTION file
    # ^DIC(4). The distinction matters: off this box, an INSTITUTION IEN is the
    # wrong value here and would file (or DINUM the subentry to) a bad facility.
    # The 41-entry IEN == that AUTTLOC IEN; .02 is the HRN/chart number.
    HRN_SUBFILE = "9000001.41"
    HRN_LOCATION_FIELD = ".01"
    HRN_FIELD = ".02"

    # #9000001 completion fields (four-digit AUPNPAT field numbers, node-11
    # pieces): 1108 TRIBE OF MEMBERSHIP (ptr ^AUTTTRI), 1111
    # CLASSIFICATION/BENEFICIARY (ptr ^AUTTBEN), 1112 ELIGIBILITY STATUS (set
    # code), 1118 CURRENT COMMUNITY (free text). DDR FILER files INTERNAL-format
    # values — UPDATE^DIE/FILE^DIE run with no "E" flag (DDR3.m:15,18) — so
    # callers pass pointer IENs and internal set codes verbatim.
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
    #   service_connected:  internal "Y"/"N" (filed `///` into #.301, set
    #                       Y:YES;N:NO; NOT CHK^DIE-validated — VAFCPTAD.m:90-94)
    #   pob_city:/pob_state:/mothers_maiden_name:  optional (VAFCPTAD.m:21-24)
    #   hrn:                health record number to file (with location_ien:)
    #   location_ien:       facility IEN for the 41 multiple's DINUM entry
    #   tribe:/classification:/eligibility_status:/community:
    #                       optional #9000001 completion values, FileMan-INTERNAL
    #                       (pointer IENs / internal set codes — see above)
    #
    # Returns:
    #   { success: true, dfn:, created: }               — registered (created:
    #     false = idempotent re-run against an existing #9000001 record)
    #   { success: false, error: Symbol, message: }     — rejected; error is
    #     :voa_rejected / :identity_mismatch / :lock_failed / :filer_rejected
    #   nil                                             — no broker response
    def register(attrs)
      voa = DataMapper.voa_add_patient.fetch_one(voa_param(attrs))
      return nil unless voa
      return voa_failure(voa) unless voa[:status] == 1

      dfn = voa[:dfn_or_error].to_i

      # BLOCKER-3 identity guard: VOA returns "1^DFN" both for a freshly created
      # patient AND for an ICN that already exists at this facility
      # (VAFCPTAD.m:29,55), with NO identity re-validation. Verify the resolved
      # record IS the person in the request before writing anything against it.
      mismatch = identity_mismatch(attrs, dfn)
      return mismatch if mismatch

      node = "^AUPNPAT(#{dfn})"
      case DdrFileman.lock(node: node)
      when nil
        return nil # no broker response to the lock — unreachable, not a rejection
      when false
        return { success: false, error: :lock_failed,
                 message: "could not lock #{node}" }
      end

      begin
        complete_ihs_registration(attrs, dfn)
      ensure
        DdrFileman.unlock(node: node)
      end
    end

    # Steps 4-5 against an already-locked ^AUPNPAT(DFN).
    def complete_ihs_registration(attrs, dfn)
      exists = ihs_record_exists?(dfn)
      return nil if exists.nil?

      # Two FILER passes, mirroring the AG-native round trip (AUPNLK2.m:55-58;
      # rpms-ops docs/REGISTRATION_RPC_CONTRACTS.md §6): first the #9000001 stub
      # (.01/.02/.11) at the DINUM IEN, then the HRN subentry + completion
      # fields against the now-real "DFN," IENS.
      unless exists
        stub = DdrFileman.filer(mode: "ADD", rows: stub_rows(dfn), iens: { 1 => dfn })
        failure = filer_failure(stub)
        return failure unless failure == :ok
      end

      rows, pins = completion_rows(attrs, dfn)
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
        # SRVCNCTD is filed verbatim (no CHK^DIE) as internal "Y"/"N"
        # (VAFCPTAD.m:90-94; REGISTRATION_RPC_CONTRACTS.md §1).
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
      # ADD^VAFCPTAD returns "-1^text" on failure (VAFCPTAD.m:28,140). There is
      # no dedicated duplicate error — FILE^DICN runs "FLZ" with no lookup
      # screening (VAFCPTAD.m:130), and a known ICN is NOT an error (it returns
      # "1^DFN", VAFCPTAD.m:55, and is handled by the identity guard). So every
      # -1 is simply :voa_rejected; the M-side text rides `message`.
      { success: false, error: :voa_rejected, message: voa[:dfn_or_error].to_s }
    end

    # nil when the resolved DFN's identity matches the request (or cannot be
    # read back); a rejection hash when ORWPT ID INFO returns a record whose
    # name/DOB/sex disagrees with the request (wrong-patient — VOA resolved an
    # existing ICN to a different person). The message names WHICH field
    # diverged but never echoes the PHI values.
    def identity_mismatch(attrs, dfn)
      id = DataMapper.patient_id_info.fetch_one(dfn.to_s)
      return nil if id.nil? # unverifiable (no record / RPC unavailable) — don't false-reject

      want = request_identity(attrs)
      diverged = %i[sex dob last_name].select { |field| identity_field_differs?(field, want, id) }
      return nil if diverged.empty?

      { success: false, error: :identity_mismatch,
        message: "VOA resolved DFN #{dfn} to an existing patient whose " \
                 "#{diverged.join('/')} does not match the registration request" }
    end

    # Normalize the request's identity fields for comparison.
    def request_identity(attrs)
      last, first = name_pieces(attrs).split("^", 2)
      { last_name: last.to_s.upcase, first_name: first.to_s.upcase,
        sex: attrs[:sex].to_s.strip[0, 1].to_s.upcase, dob: dob_key(attrs[:dob]) }
    end

    def identity_field_differs?(field, want, id)
      case field
      when :sex
        got = id[:sex].to_s.strip[0, 1].to_s.upcase
        !got.empty? && !want[:sex].empty? && got != want[:sex]
      when :dob
        got = dob_key(id[:dob])
        !got.empty? && !want[:dob].empty? && got != want[:dob]
      when :last_name
        # id[:name] is "LAST,FIRST MIDDLE"; compare last-name tokens only.
        got = id[:name].to_s.split(",", 2).first.to_s.strip.upcase
        !got.empty? && !want[:last_name].empty? && got != want[:last_name]
      end
    end

    # Reduce a DOB (Date/Time, a parsed FileMan Date from the mapping, or an
    # external string) to a comparable YYYYMMDD key; "" when it can't be read.
    def dob_key(value)
      return value.strftime("%Y%m%d") if value.is_a?(Date) || value.is_a?(Time)
      digits = value.to_s.gsub(/\D/, "")
      # "MM/DD/YYYY" external → YYYYMMDD; leave already-8-digit values as-is.
      if value.to_s =~ %r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z}
        format("%04d%02d%02d", $3.to_i, $1.to_i, $2.to_i)
      else
        digits
      end
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
      probe = DdrFileman.gets_entry(file: PATIENT_FILE, iens: "#{dfn},", fields: STUB_NAME_FIELD)
      return nil unless probe
      !probe[:error] && !probe[:fields].empty?
    end

    def filer_failure(filed)
      return nil if filed.nil?
      return :ok if filed[:success]
      { success: false, error: :filer_rejected, message: filed[:errors].join("; ") }
    end

    # #9000001 stub: .01 (name pointer, DINUM'd to the DFN via the "+1,"
    # placeholder pinned to DFN), .02 DATE ESTABLISHED = today's FileMan date,
    # .11 ESTABLISHING USER = the authenticated session DUZ (AUPNLK2.m:57
    # files `.02////`_DT_`;.11////`_DUZ). DDR FILER files INTERNAL values, so
    # .02 is the internal FileMan date. .11 is filed only when the client knows
    # its DUZ; when it doesn't (no DUZ bound to the session) the pointer-to-200
    # field is omitted rather than filed with a fabricated user.
    def stub_rows(dfn)
      rows = [
        { file: PATIENT_FILE, field: STUB_NAME_FIELD, iens: "+1,", value: dfn },
        { file: PATIENT_FILE, field: STUB_DATE_FIELD, iens: "+1,",
          value: FilemanDateParser.format_date(Date.today) }
      ]
      duz = session_duz
      rows << { file: PATIENT_FILE, field: STUB_USER_FIELD, iens: "+1,", value: duz } if duz
      rows
    end

    # The authenticated session's DUZ, when the client exposes one (CiaClient
    # captures it at sign-on, #178). Returns nil when unknown.
    def session_duz
      client = RpmsRpc.client
      duz = client.respond_to?(:duz) ? client.duz : nil
      duz.to_s.empty? ? nil : duz.to_s
    end

    # Build the completion-pass DDR FILER rows against the existing #9000001
    # record ("DFN," IENS). All values are FileMan-INTERNAL — the filer runs
    # UPDATE^DIE/FILE^DIE with no "E" flag (DDR3.m:15,18).
    #
    # The 41-multiple HRN entry is DINUM'd to the facility IEN (.01's
    # `S DINUM=X`), so re-filing on an idempotent re-run UPDATEs the same
    # subentry rather than adding a duplicate — no pre-check needed (and none is
    # possible: HRN uniqueness is not FileMan-enforced; see the module header).
    def completion_rows(attrs, dfn)
      rows = []
      pins = {}

      hrn = attrs[:hrn]&.to_s
      if hrn && !hrn.empty?
        location = attrs[:location_ien].to_s
        raise ArgumentError, "registration location_ien is required to file an HRN" if location.empty?
        sub_iens = "+1,#{dfn},"
        rows << { file: HRN_SUBFILE, field: HRN_LOCATION_FIELD, iens: sub_iens, value: location }
        rows << { file: HRN_SUBFILE, field: HRN_FIELD, iens: sub_iens, value: hrn }
        pins[1] = location
      end

      OPTIONAL_FIELD_MAP.each do |key, field|
        value = attrs[key]
        next if value.nil? || value.to_s.empty?
        rows << { file: PATIENT_FILE, field: field, iens: "#{dfn},", value: value.to_s }
      end

      [ rows, pins ]
    end
  end
end
