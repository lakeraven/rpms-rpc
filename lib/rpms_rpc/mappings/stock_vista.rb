# frozen_string_literal: true

require_relative "../data_mapper"

# Stock-VistA RPC response mappings (kernel + clinical namespaces that
# exist on any VistA: ORW*/ORQQ*/TIU/XUS/DDR/VAFC/...).
# Bucketed here ahead of the vista-rpc extraction; registers into the
# same DataMapper registry as mappings/ihs.rb. Loaded via
# `require "rpms_rpc/mappings"` — see ../mappings.rb.
module RpmsRpc
  module Mappings
    # ========================================================================
    # PATIENT (ORWPT*)
    # ========================================================================

    # ORWPT SELECT — core patient demographics
    # Format: NAME^SEX^DOB^SSN^LOCIEN^LOCNM^RMBD^CWAD^SENSITIVE^ADMITTED^CONV^SC^SC%^ICN^AGE^TS
    DataMapper.define(:patient_select) do |m|
      m.rpc "ORWPT SELECT"
      m.field 0,  :name
      m.field 1,  :sex
      m.field 2,  :dob,       :fileman_date
      m.field 3,  :ssn
      m.field 14, :age,       :integer
    end

    # ORWPT ID INFO — patient identifier projection.
    # Verified format (IDINFO^ORWPT: ORWPT.m:6-11 — header line 7
    # "PID^DOB^SEX^VET^SC%^WARD^RM-BED^NAME", REC construction line 10):
    #   PID[1]^DOB[2]^SEX[3]^VET[4]^SC%[5]^WARD[6]^RM-BED[7]^NAME[8]
    # VET is the VETERAN (Y/N) flag and WARD the current ward location.
    # The prior declaration read piece 4 as :race_code and piece 6 as
    # :site_ien — the captured "N" at piece 4 is the veteran flag, and
    # piece 6 is empty for an outpatient; neither value was ever what it
    # claimed (#191, caught by the wire-contract gate against
    # test/fixtures/wire_captures/orwpt-id-info.yml).
    # Despite the "ID INFO" name, this RPC does NOT return address,
    # city, state, zip, phone, tribal enrollment, service area, or
    # coverage — those fields were hallucinated in the prior mapping and
    # have NO known RPC source (an earlier attribution to an invented RPC
    # family was removed — docs/RPC_COVERAGE.md provenance notes). IHS
    # demographic/tribal detail lives in file #9000001 (^AUPNPAT), read
    # via DDR GETS ENTRY DATA (RpmsRpc::Tribal / RpmsRpc::DdrFileman).
    DataMapper.define(:patient_id_info) do |m|
      m.rpc "ORWPT ID INFO"
      m.field 0, :ssn
      m.field 1, :dob, :fileman_date
      m.field 2, :sex
      m.field 3, :veteran
      m.field 4, :sc_percent
      m.field 5, :ward_location
      m.field 6, :room_bed
      m.field 7, :name
    end

    # ORWPT LIST ALL — patient search results (multi-line)
    # Wire format is at least DFN^NAME. Some sites may append fields; mocks may seed
    # SEX and DOB for parity with FHIR Patient?name&birthdate|gender filters. Missing
    # trailing pieces parse as nil via DataMapper#coerce.
    DataMapper.define(:patient_list) do |m|
      m.rpc "ORWPT LIST ALL"
      m.field 0, :dfn, :integer
      m.field 1, :name
      m.field 2, :sex
      m.field 3, :dob, :fileman_date
    end

    # ORWPT FULLSSN — SSN lookup. Live shape against staging
    # (Mickey's SSN 000009999):
    #   "3^MOUSE,MICKEY M^2100214^000009999"
    DataMapper.define(:patient_ssn) do |m|
      m.rpc "ORWPT FULLSSN"
      m.field 0, :dfn,  :integer
      m.field 1, :name
      m.field 2, :dob,  :fileman_date
      m.field 3, :ssn
    end

    # ORWPT APPTLST — patient appointments (multi-line)
    # Format: APPTTIME^LOCIEN^LOCNAME^EXTSTATUS
    DataMapper.define(:patient_appointments) do |m|
      m.rpc "ORWPT APPTLST"
      m.field 0, :datetime,     :fileman_date
      m.field 1, :location_ien, :integer
      m.field 2, :location
      m.field 3, :status
    end

    # ORQQAL LIST — patient allergies (multi-line)
    # Wire per LIST^ORQQAL (ORQQAL.m:8,14 over EN1^GMRAOR1):
    #   ALLERGY_IEN ^ AGENT ^ SEVERITY ^ SIGNS(";"-joined — ORQQAL.m:18-21)
    # Assessment-state sentinels "^No Allergy Assessment" / "^No Known
    # Allergies" / "^No allergies found." (ORQQAL.m:12-15) are filtered by
    # DataMapper's sentinel guard; the three-state assessment result is
    # surfaced by RpmsRpc::Allergy.assessment.
    DataMapper.define(:allergy_list) do |m|
      m.rpc "ORQQAL LIST"
      m.field 0, :ien
      m.field 1, :allergen
      m.field 2, :severity
      m.field 3, :signs
    end

    # ORQQPL LIST — patient problem list (multi-line).
    # Verified format (LIST^ORQQPL: ORQQPL.m:3-18 — the row is a reshuffle
    # of the LIST^GMPLUTL3 array, GMPLUTL3.m:76-124: IFN^ST^NARR^ICD^ONSET^
    # LASTMOD^SC^SP^priority^transcribed^SCTC^SCTD; ORQQPL emits
    # $P(X,U)_U_$P(X,U,3)_U_$P(X,U,2)_U_$P(X,U,4..8)_U_$P(X,U,10)_U_
    # $P(X,U,9)_U_""_U_DETAIL):
    #   IEN[1]^NARRATIVE[2]^STATUS[3]^ICD[4]^ONSET[5]^LAST MODIFIED[6]^
    #   SC[7]^SPEXP[8]^TRANSCRIBED($)[9]^PRIORITY(*)[10]^^DETAIL[12]
    # STATUS is #9000011 field .12 internal ("A"/"I" — GMPLUTL3.m NODE0
    # "$P(GMPLZ0,U,12)"). The prior declaration swapped STATUS and
    # DESCRIPTION and invented RECORDED_DATE / PROVIDER_DUZ at pieces 6-7
    # (really LAST MODIFIED — ^AUPNPROB 0-node piece 3 — and SERVICE
    # CONNECTED): same fabrication class as the old ORQQVI mapping. "No
    # problems" comes back as the sentinel row "^No problems found."
    # (ORQQPL.m:17) — piece 1 empty, so :ien is blank and callers drop it.
    DataMapper.define(:problem_list) do |m|
      m.rpc "ORQQPL LIST"
      m.field 0, :ien
      m.field 1, :description
      m.field 2, :status
      m.field 3, :icd_code, :string, terminology: :icd10
      m.field 4, :onset_date,    :fileman_date
      m.field 5, :last_modified, :fileman_date
      m.field 6, :service_connected
      m.field 7, :special_exposures
      m.field 8, :transcribed
      m.field 9, :priority
    end

    # ORQQPL coverage — problem-list mutations + lookups + audit. Wire field
    # formats below are best-effort pending broker trace capture; mapping
    # names + RPC bindings are deliberate so the API layer can dispatch
    # without re-deriving names. Callers using fetch_scalar / fetch_many on
    # these mappings will get raw strings + simple keyed rows respectively.

    DataMapper.define(:problem_add_save) do |m|
      m.rpc "ORQQPL ADD SAVE"
    end

    # Best-effort field positions pending broker trace capture for
    # problem_audit_history / problem_comments / problem_detail /
    # problem_clinic_search / problem_lex_search / problem_provider_list /
    # problem_edit_load — wire formats below mirror the closest analogous
    # ORQQPL RPC (problem_list) and the standard VistA "IEN^DESCRIPTION..."
    # convention. Refine when trace capture lands.

    DataMapper.define(:problem_audit_history) do |m|
      m.rpc "ORQQPL AUDIT HIST"
      m.field 0, :event
      m.field 1, :date, :fileman_date
      m.field 2, :actor
    end

    DataMapper.define(:problem_check_duplicate) do |m|
      m.rpc "ORQQPL CHECK DUP"
    end

    DataMapper.define(:problem_clinic_filter_list) do |m|
      m.rpc "ORQQPL CLIN FILTER LIST"
    end

    DataMapper.define(:problem_clinic_search) do |m|
      m.rpc "ORQQPL CLIN SRCH"
      m.field 0, :ien
      m.field 1, :description
    end

    DataMapper.define(:problem_delete) do |m|
      m.rpc "ORQQPL DELETE"
    end

    DataMapper.define(:problem_detail) do |m|
      m.rpc "ORQQPL DETAIL"
      m.field 0, :ien
      m.field 1, :status
      m.field 2, :description
    end

    DataMapper.define(:problem_edit_load) do |m|
      m.rpc "ORQQPL EDIT LOAD"
      m.field 0, :ien
      m.field 1, :status
      m.field 2, :description
    end

    DataMapper.define(:problem_edit_save) do |m|
      m.rpc "ORQQPL EDIT SAVE"
    end

    DataMapper.define(:problem_inactivate) do |m|
      m.rpc "ORQQPL INACTIVATE"
    end

    DataMapper.define(:problem_init_patient) do |m|
      m.rpc "ORQQPL INIT PT"
      m.field 0, :dfn
      m.field 1, :name
    end

    DataMapper.define(:problem_init_user) do |m|
      m.rpc "ORQQPL INIT USER"
    end

    DataMapper.define(:problem_comments) do |m|
      m.rpc "ORQQPL PROB COMMENTS"
      m.field 0, :date, :fileman_date
      m.field 1, :author
      m.field 2, :comment
    end

    DataMapper.define(:problem_lex_search) do |m|
      m.rpc "ORQQPL PROBLEM LEX SEARCH"
      m.field 0, :code, :string, terminology: :icd10
      m.field 1, :description
    end

    DataMapper.define(:problem_problem_list) do |m|
      m.rpc "ORQQPL PROBLEM LIST"
    end

    DataMapper.define(:problem_provider_filter_list) do |m|
      m.rpc "ORQQPL PROV FILTER LIST"
    end

    DataMapper.define(:problem_provider_list) do |m|
      m.rpc "ORQQPL PROVIDER LIST"
      m.field 0, :duz, :string, pointer: { file: 200 }
      m.field 1, :name
    end

    DataMapper.define(:problem_replace) do |m|
      m.rpc "ORQQPL REPLACE"
    end

    DataMapper.define(:problem_save_view) do |m|
      m.rpc "ORQQPL SAVEVIEW"
    end

    DataMapper.define(:problem_service_filter_list) do |m|
      m.rpc "ORQQPL SERV FILTER LIST"
    end

    DataMapper.define(:problem_service_search) do |m|
      m.rpc "ORQQPL SRVC SRCH"
    end

    DataMapper.define(:problem_update) do |m|
      m.rpc "ORQQPL UPDATE"
    end

    DataMapper.define(:problem_user_categories) do |m|
      m.rpc "ORQQPL USER PROB CATS"
    end

    DataMapper.define(:problem_user_list) do |m|
      m.rpc "ORQQPL USER PROB LIST"
    end

    DataMapper.define(:problem_verify) do |m|
      m.rpc "ORQQPL VERIFY"
    end

    # ORQQVI VITALS — the patient's MOST RECENT vital per type, optionally
    # within a date range. NOT full history: the #8994 registry dispatches
    # this RPC name to FASTVIT^ORQQVI
    # (.broker_dumps_8994_20260607.txt:565 "ORQQVI VITALS^FASTVIT^ORQQVI"),
    # which returns at most ONE row per vital type — the newest in range
    # (FASTVIT^ORQQVI: ORQQVI.m:64-91; per-type newest-first walk with
    # `Q:OK` — VITAL^ORQQVI: ORQQVI.m:104-105, MSR^ORQQVI: ORQQVI.m:170-171).
    # Params: DFN, start date, end date (FileMan; both optional —
    # ORQQVI.m:74-78 defaults to all time).
    # Verified format (header ORQQVI.m:66-67 "vital measurement ien^vital
    # type^rate^date/time taken"; row construction ORQQVI.m:113 (VA path) /
    # ORQQVI.m:179 (IHS V MEASUREMENT path, taken when DUZ("AG")="I" —
    # ORQQVI.m:96)):
    #   MEASUREMENT_IEN[1]^TYPE[2]^VALUE(rate)[3]^DATETIME[4]^
    #   DISPLAY[5]^METRIC_DISPLAY[6]^QUALIFIERS[7]
    # An earlier revision of this mapping declared IEN^TYPE^DATETIME^VALUE —
    # that shape belongs to a DIFFERENT registered RPC, "ORQQVI VITALS FOR
    # DATE RANGE" → VITALS^ORQQVI (see :vitals_for_date_range below); the
    # mapping had been verified against the wrong routine tag. Resolve the
    # registry name→tag row FIRST, then read that tag.
    # TYPE abbreviations differ by path: the IHS branch emits ^AUTTMSR
    # abbreviations (TMP/PU/RS/BP/HT/WT/PA/O2 — ORQQVI.m:164), the VA
    # branch T/P/R/BP/HT/WT/PN/POX. On the IHS branch MEASUREMENT_IEN is a
    # V MEASUREMENT (#9000010.01) IEN (^PXRMINDX(9000010.01,...) walk,
    # ORQQVI.m:170-171); on the VA branch it is a GMRV #120.5 IEN.
    # DISPLAY is the value with US unit text ("98.6 F"), METRIC_DISPLAY the
    # conversion ("(37.0 C)") where one applies (ORQQVI.m:180-223);
    # QUALIFIERS is piece 7 (ORQQVI.m:224). POX rows carry supplemental O2
    # flow at piece 8 (ORQQVI.m:211) — undeclared here. There is NO units
    # piece and NO sentinel row: FASTVIT returns nothing when no vitals
    # exist (the "^No vitals found." sentinel belongs to VITALS^ORQQVI,
    # ORQQVI.m:24). Callers needing units/service-category should use
    # RpmsRpc::Measurement (BGOVMSR + BEHOENCX + BEHOVM2 composition).
    #
    # SITE CAVEAT — on an IHS-agency box running the SHIPPED routine this
    # RPC returns ONE row, not one per type. VITAL^ORQQVI dispatches to
    # MSR^ORQQVI passing the row counter BY VALUE
    # ("D MSR(VITAL,ABBREV,DFN,.ORY,CNT,F1,F2)" — bcer-9.0-ydb
    # r/ORQQVI.m:96; note CNT with no leading dot), so each per-type call
    # resets the counter and every vital overwrites ORY(1) — only the last
    # type walked survives. rpms-ops carries a corrected overlay passing
    # ".CNT" (reconciliation/yottadb-ubuntu/ORQQVI.m:103). A single-row
    # reply for a patient with several vitals is this bug, not an empty
    # chart: check the site's routine before chasing the data.
    DataMapper.define(:vitals) do |m|
      m.rpc "ORQQVI VITALS"
      m.field 0, :measurement_ien, :integer
      m.field 1, :type
      m.field 2, :value
      m.field 3, :recorded_date, :fileman_datetime
      m.field 4, :display
      m.field 5, :metric_display
      m.field 6, :qualifiers
    end

    # ORQQVI VITALS FOR DATE RANGE — every vital in a date range, one row
    # per measurement (registry: .broker_dumps_8994_20260607.txt:795
    # "ORQQVI VITALS FOR DATE RANGE^VITALS^ORQQVI"). Params: DFN, start,
    # end (FileMan date/times).
    # Verified format (VITALS^ORQQVI: ORQQVI.m:4-26 — header ORQQVI.m:6
    # "vital measurement ien^vital type^date/time taken^rate", row
    # construction ORQQVI.m:23):
    #   MEASUREMENT_IEN[1]^TYPE[2]^DATETIME[3]^VALUE(rate)[4]
    # HONEST LIMITATION — this tag reads ONLY the GMRV VITAL MEASUREMENT
    # file (#120.5) via EN1^GMRVUT0 (ORQQVI.m:13-16) and, unlike
    # VITAL^ORQQVI (ORQQVI.m:96), has NO IHS DUZ("AG")="I" branch: on an
    # RPMS system whose vitals live only in V MEASUREMENT (#9000010.01) it
    # returns the sentinel row "^No vitals found." (ORQQVI.m:24 — piece 1
    # empty, so :measurement_ien is nil and callers drop it). Where rows DO
    # come back, MEASUREMENT_IEN is a #120.5 IEN — NOT a V MEASUREMENT
    # IEN; do not feed it to #9000010.01 reads (DDR GETS, Measurement.find).
    DataMapper.define(:vitals_for_date_range) do |m|
      m.rpc "ORQQVI VITALS FOR DATE RANGE"
      m.field 0, :measurement_ien, :integer
      m.field 1, :type
      m.field 2, :recorded_date, :fileman_datetime
      m.field 3, :value
    end

    # ========================================================================
    # PRACTITIONER (ORWU*)
    # ========================================================================

    # ORWU USERINFO — info about the AUTHENTICATED session user. Takes
    # no params; broker raises <PARAMETER> when given any. Returns a
    # single 25-piece caret-delimited line. Live shape against staging
    # (DUZ=1 PROVIDER,TEST):
    #   "1^PROVIDER,TEST^3^...^DEMO.IHS.GOV^...^8904^"
    # The prior declaration aligned NAME^TITLE^SERVICE_SECTION^... at
    # position 0; in reality position 0 is DUZ and the rest of the
    # "demographic" fields (title, service_section, specialty, npi,
    # dea_number, phone, provider_class) were invented — those are not
    # in this response at all. Only fields with verified semantics are
    # declared here; intermediate positions are small integer codes
    # whose meaning would need the kernel data dictionary to interpret.
    DataMapper.define(:practitioner_info) do |m|
      m.rpc "ORWU USERINFO"
      m.field 0,  :duz,           :integer
      m.field 1,  :name
      m.field 2,  :user_class,    :integer
      m.field 12, :kernel_domain
      m.field 23, :site_ien,      :integer
    end

    # ORWU NEWPERS — multi-line user/practitioner search. Live shape
    # against staging is IEN^NAME (2 pieces); the TITLE piece declared
    # in earlier versions doesn't appear in this broker's response.
    # IEN/DUZ kept as :string because FileMan permits fractional IENs
    # (e.g., ".5" for Postmaster, ".6" for Shared,Mail) which :integer
    # coercion would collapse to 0.
    DataMapper.define(:practitioner_list) do |m|
      m.rpc "ORWU NEWPERS"
      m.field 0, :ien
      m.field 1, :name
    end

    DataMapper.define(:user_management_user_list) do |m|
      m.rpc "ORWU NEWPERS"
      m.field 0, :duz
      m.field 1, :name
    end

    # ========================================================================
    # CLINICAL DATA (ORQQPS*)
    # ========================================================================

    # ORQQPS LIST — condensed medication list (multi-line). Registry:
    # .broker_dumps_8994_20260607.txt:576 "ORQQPS LIST^LIST^ORQQPS".
    # Verified format (LIST^ORQQPS: ORQQPS.m:4-55 — header ORQQPS.m:5
    # "id^nameform^stop date^route^schedule/infusion rate^refills
    # remaining"; row construction ORQQPS.m:32/37 (IV), 42 (unit dose),
    # 47 (outpatient)):
    #   ID[1]^NAME[2]^STOP_DATE[3]^ROUTE[4]^SCHEDULE[5]^REFILLS[6]
    # ID is the pharmacy order id string PSOORRL emits (e.g. "403R;O") —
    # NOT a bare file-50 pointer. STOP_DATE is FileMan (piece 4 of the
    # ^TMP("PS") node — the reverse-chronology sort key, ORQQPS.m:45).
    # SCHEDULE carries the infusion rate for IV rows (ORQQPS.m:32) and the
    # schedule otherwise; REFILLS is present on outpatient rows only
    # (ORQQPS.m:47). The prior declaration
    # (IEN^DRUG_NAME^SIG^STATUS^LAST_FILL^REFILLS^PROVIDER) was fabricated —
    # there is no SIG/STATUS/PROVIDER piece on this wire. "No medications"
    # comes back as the sentinel row "^No medications found."
    # (ORQQPS.m:53) — piece 1 empty, so :id is blank and callers drop it.
    DataMapper.define(:medication_list) do |m|
      m.rpc "ORQQPS LIST"
      m.field 0, :id
      m.field 1, :name, :string, terminology: :rxnorm
      m.field 2, :stop_date, :fileman_date
      m.field 3, :route
      m.field 4, :schedule
      m.field 5, :refills, :integer
    end

    # ========================================================================
    # AUTHENTICATION (XUS*)
    # ========================================================================

    # XUS GET USER INFO — authenticated user info. Response is line-based,
    # one value per line — not caret-delimited. The layout is USERINFO^XUSRB2's
    # RET() array (XUSRB2.m:25-35), confirmed against a built 9.0 image:
    #   [0] "1"                              → duz (:25)
    #   [1] "PROVIDER,TEST"                  → name, file 200 .01 (:29)
    #   [2] "Adam Adam"                      → display_name, $$NAME^XUSER (:30)
    #   [3] "7819^DEMO IHS CLINIC^8904"      → current_site, DUZ(2)^$$NS^XUAF4 (:31)
    #   [4] ""                               → title, file 3.1 name (:32)
    #   [5] ""                               → service/section, file 49 name (:33)
    #   [6] ""                               → DUZ("LANG") (:34)
    #   [7] "30"                             → DTIME, the user's timed-read (:35)
    # Line 7 was declared as a user-class pointer. It is DTIME; nothing in
    # this reply is a user class (#236).
    DataMapper.define(:user_info) do |m|
      m.rpc "XUS GET USER INFO"
      m.line_field 0, :duz,  :integer
      m.line_field 1, :name
      m.line_field 2, :display_name
      m.line_field 3, :current_site
      m.line_field 7, :dtime, :integer
    end

    # ========================================================================
    # HEALTH SUMMARY & REMINDERS (ORWRP*, ORQQPX*)
    # ========================================================================

    # ORQQPX REMINDERS LIST — clinical reminders (multi-line)
    # Format: IEN^NAME^STATUS^DUE_DATE^LAST_DONE^PRIORITY
    DataMapper.define(:reminders_list) do |m|
      m.rpc "ORQQPX REMINDERS LIST"
      m.field 0, :ien, :integer
      m.field 1, :name
      m.field 2, :status
      m.field 3, :due_date,  :fileman_date
      m.field 4, :last_done, :fileman_date
      m.field 5, :priority
    end

    # ORQQPXRM REMINDERS APPLICABLE: the reminder engine's own evaluation of
    # a patient's cover-sheet reminders, the method RPMS has in place for
    # "which reminders apply, with status, due date and priority" (#238).
    # APPL^ORQQPXRM (ORQQPXRM.m:10-11) -> EVALCOVR^ORQQPX (ORQQPX.m:232-236):
    # GETLIST (the UNEVALUATED list, ORQQPX.m:225-231) then ALIST^PXRMRPCA
    # (the REMINDER EVALUATION path) -> AVAL (PXRMRPCA.m:49-82).
    # Params: ORPT (DFN), ORLOC (#44 hospital location; selects which
    # cover-sheet reminders are evaluated, REMLIST ORQQPX.m:185-206).
    # One row per reminder (PXRMRPCA.m:76 applicable, :80 not applicable):
    #   IEN^PRINT NAME^DUE DATE^LAST DONE^PRIORITY^DUE FLAG^DIALOG^^^^WIPE
    # - DUE DATE is kept RAW: a FileMan date, or the text "DUE NOW"
    #   (PXRMDATE.m:132), "CNBD" (:129), "DISABLED" (PXRM.m:62), or empty
    #   (PXRMDATE.m:119; PXRMOUTD.m:24,29; not-applicable rows).
    # - LAST DONE is emptied when not a date (PXRMRPCA.m:70).
    # - PRIORITY is #811.9 piece 10, default 2 (:72-74); empty on N/A rows.
    # - DUE FLAG: 0 applicable, 1 due, 2 not applicable, 3 error,
    #   4 cannot be determined (:56-67).
    # - DIALOG = $$DLG (:112-117); WIPE = $$DLGWIPE (:119-123).
    DataMapper.define(:reminders_applicable) do |m|
      m.rpc "ORQQPXRM REMINDERS APPLICABLE"
      m.field 0,  :ien,         :integer
      m.field 1,  :print_name
      m.field 2,  :due_date
      m.field 3,  :last_done,   :fileman_date
      m.field 4,  :priority,    :integer
      m.field 5,  :due_flag,    :integer
      m.field 6,  :dialog,      :boolean
      m.field 10, :dialog_wipe, :boolean
    end

    # ORQQPX REMINDER DETAIL — single reminder detail (text blob)
    DataMapper.define(:reminder_detail) do |m|
      m.rpc "ORQQPX REMINDER DETAIL"
      m.text_blob :detail_text
    end

    # ========================================================================
    # SCALAR / BOOLEAN RPCs
    # ========================================================================

    # ORWPT DIEDON — deceased check (FileMan date or "0")
    DataMapper.define(:patient_deceased) do |m|
      m.rpc "ORWPT DIEDON"
      m.scalar :deceased_date, :fileman_date
    end

    # ORWPT SELCHK — sensitive record check ("1" if sensitive)
    DataMapper.define(:patient_sensitive) do |m|
      m.rpc "ORWPT SELCHK"
      m.scalar :sensitive, :boolean
    end

    # ORWU HASKEY — security key check
    DataMapper.define(:user_has_key) do |m|
      m.rpc "ORWU HASKEY"
      m.scalar :has_key, :boolean
    end

    # ORWU NPHASKEY — does person NP hold KEY: NPHASKEY^ORWU(VAL,NP,KEY),
    # ''$D(^XUSEC(KEY,NP)). ORWU HASKEY takes the key only and answers for
    # the signed-on DUZ; sending it a DUZ too is %YDB-E-ACTLSTTOOLONG (#296).
    DataMapper.define(:person_has_key) do |m|
      m.rpc "ORWU NPHASKEY"
      m.scalar :has_key, :boolean
    end

    # ========================================================================
    # LINE-BASED RESPONSES
    # ========================================================================

    # XUS SIGNON SETUP — signon setup (returns "OK" or error)
    DataMapper.define(:signon_setup) do |m|
      m.rpc "XUS SIGNON SETUP"
      m.scalar :status, :string
    end

    # XUS AV CODE — authentication result, one value per line. The reply is
    # VALIDAV^XUSRB's RET() array (XUSRB.m:9-11, :16, :40, :85-87):
    #   RET(0)=DUZ (0 on failure)
    #   RET(1)=XUM — 0 ok; 1 can't sign on (inhibited logons, three-strike lock)
    #   RET(2)=VCCH — verify code needs changing
    #   RET(3)=message — $$TXT^XUS3(XUMSG), "" on success
    #   RET(4)=0
    #   RET(5)=post-sign-on message COUNT: 0 at entry (:16); set to the number
    #          of XUTEXT lines in POST (:86), zeroed when $$SHOWPOST is off (:87)
    #   RET(5+n)=the message lines themselves (:86)
    #   RET(RET(5)+6)=number of divisions the user must choose from (:11)
    # Line 5 used to be declared as a user class. No line of this reply is one
    # (#236); the role comes from security keys — see UserRoles.
    DataMapper.define(:av_code) do |m|
      m.rpc "XUS AV CODE"
      m.line_field 0, :duz, :integer
      # RAW, not :integer: " ".to_i == 0, so integer coercion read a
      # whitespace-only error line as a zero-error SUCCESS. The consumer
      # (Authentication#parse_auth_response) requires this line to be
      # actually numeric before it converts.
      m.line_field 1, :error_code
      m.line_field 2, :verify_needs_change, :integer
      m.line_field 3, :message
      m.line_field 5, :post_signon_message_count, :integer
    end

    # XUS CVC — CVC verification
    DataMapper.define(:cvc_verify) do |m|
      m.rpc "XUS CVC"
      m.line_field 0, :result_code, :integer
    end

    # ========================================================================
    # TEXT BLOB RESPONSES (free text reports)
    # ========================================================================

    # ORWRP REPORT TEXT — health summary report text
    DataMapper.define(:report_text) do |m|
      m.rpc "ORWRP REPORT TEXT"
      m.text_blob :report_text
    end

    # ========================================================================
    # CLINICAL DETAIL (single-record GET RPCs)
    # ========================================================================

    # ORQQPS DETAIL — medication detail (text blob)
    DataMapper.define(:medication_detail) do |m|
      m.rpc "ORQQPS DETAIL"
      m.text_blob :detail_text
    end

    # ========================================================================
    # TIU NOTE TEMPLATES (TIU TEMPLATE*)
    # ========================================================================
    # Templates form a tree (roots -> items). GETROOTS and GETITEMS rows are
    # NODEDATA^TIUSRVT (TIUSRVT.m:104-109), whose pieces TIUSRVT.m:4-29
    # list: IEN^TYPE^STATUS^NAME^EXCLUDE FROM GROUP BOILERPLATE^BLANK
    # LINES^PERSONAL OWNER^HAS CHILDREN (0 none, 1 active, 2 inactive,
    # 3 both)^... A GETITEMS row names no parent: it is a child of the
    # TIUDA asked about (#219).

    DataMapper.define(:template_roots) do |m|
      m.rpc "TIU TEMPLATE GETROOTS"
      m.field 0, :ien, :integer
      m.field 1, :type
      m.field 2, :status
      m.field 3, :name
      m.field 4, :exclude_from_group_boilerplate
      m.field 5, :blank_lines, :integer
      m.field 6, :personal_owner_duz
      m.field 7, :has_children, :integer
    end

    DataMapper.define(:template_items) do |m|
      m.rpc "TIU TEMPLATE GETITEMS"
      m.field 0, :ien, :integer
      m.field 1, :type
      m.field 2, :status
      m.field 3, :name
      m.field 4, :exclude_from_group_boilerplate
      m.field 5, :blank_lines, :integer
      m.field 6, :personal_owner_duz
      m.field 7, :has_children, :integer
    end

    # GETBOIL(TIUY,TIUDA)^TIUSRVT (TIUSRVT.m:55): the template's
    # UNEXPANDED boilerplate, one line per node.
    DataMapper.define(:template_boilerplate) do |m|
      m.rpc "TIU TEMPLATE GETBOIL"
      m.text_blob :body
    end

    DataMapper.define(:template_text) do |m|
      m.rpc "TIU TEMPLATE GETTEXT"
      m.text_blob :body
    end

    DataMapper.define(:template_access_level) do |m|
      m.rpc "TIU TEMPLATE ACCESS LEVEL"
      m.scalar :level
    end

    # ========================================================================
    # TIU PROGRESS NOTES (TIU*)
    # ========================================================================
    # Every reply below is a status string the API reads, not a boolean:
    # LOCK answers 0 when it HOLDS the lock and "1^message" when it does
    # not (TIUSRVP.m:211-212), the reverse of a :boolean read (#219).

    # MAKE(SUCCESS,DFN,TITLE,VDT,VLOC,VSIT,...)^TIUSRVP (TIUSRVP.m:7):
    # the new note IEN, or "0^message".
    DataMapper.define(:tiu_create_record) do |m|
      m.rpc "TIU CREATE RECORD"
      m.scalar :note_ien
    end

    # CONTEXT(TIUY,CLASS,CONTEXT,DFN,...)^TIUSRVLO (TIUSRVLO.m:16). Each
    # row is DA_U_$$RESOLVE(DA) (TIUSRVLO.m:94); RESOLVE builds
    # DOC^EDT^PT^AUT^LOC^STATUS^TIUADT^TIUDDT^... (TIUSRVLO.m:197), AUT
    # being DUZ;SIGNATURE NAME;NAME (TIUSRVLO.m:195). The API splits it.
    DataMapper.define(:tiu_documents_by_context) do |m|
      m.rpc "TIU DOCUMENTS BY CONTEXT"
      m.field 0, :ien, :integer
      m.field 1, :title
      m.field 2, :datetime, :fileman_datetime
      m.field 3, :patient
      m.field 4, :author
      m.field 5, :location
      m.field 6, :status
      m.field 7, :visit
      m.field 8, :discharge
    end

    DataMapper.define(:tiu_get_record_text) do |m|
      m.rpc "TIU GET RECORD TEXT"
      m.text_blob :body
    end

    # CANDO(TIUY,TIUDA,TIUACT)^TIUSRVA (TIUSRVA.m:20): 1, or "0^reason".
    DataMapper.define(:tiu_authorization) do |m|
      m.rpc "TIU AUTHORIZATION"
      m.scalar :result
    end

    # LOCK(ERR,TIUDA)^TIUSRVP (TIUSRVP.m:210-212): 0 = locked,
    # "1^ Another session has this record locked." = not.
    DataMapper.define(:tiu_lock_record) do |m|
      m.rpc "TIU LOCK RECORD"
      m.scalar :result
    end

    # UNLOCK(ERR,TIUDA)^TIUSRVP (TIUSRVP.m:214-215): always 0.
    DataMapper.define(:tiu_unlock_record) do |m|
      m.rpc "TIU UNLOCK RECORD"
      m.scalar :result
    end

    # SETTEXT(TIUY,TIUDA,TIUX,SUPPRESS)^TIUSRVPT (TIUSRVPT.m:7):
    # TIUDA^PAGE^PAGES, or "0^0^0^message" (TIUSRVPT.m:10, 14, 38).
    DataMapper.define(:tiu_set_document_text) do |m|
      m.rpc "TIU SET DOCUMENT TEXT"
      m.scalar :result
    end

    # ========================================================================
    # E-SIGNATURE (ORWU VALIDSIG, TIU SIGN RECORD, TIU DELETE RECORD)
    # Wire shapes verified against the M source (ORWU / TIUSRVP / TIUSRVA)
    # and the RPC registry (file 8994); see RpmsRpc::ESignature for the
    # full contract. Encrypted params are built by the API layer.
    # ========================================================================

    # VALIDSIG(ESOK,X)^ORWU — one param: XWB-encrypted signature code.
    DataMapper.define(:tiu_valid_signature) do |m|
      m.rpc "ORWU VALIDSIG"
      m.scalar :valid, :boolean
    end

    # SIGN(ERR,TIUDA,TIUX)^TIUSRVP — params: note IEN, encrypted sig code.
    DataMapper.define(:tiu_sign_record) do |m|
      m.rpc "TIU SIGN RECORD"
      m.scalar :result
    end

    # DELETE(ERR,TIUDA,TIURSN,OVRRIDE)^TIUSRVP — params: note IEN,
    # deletion reason, override flag.
    DataMapper.define(:tiu_delete_record) do |m|
      m.rpc "TIU DELETE RECORD"
      m.scalar :result
    end

    # WHATACT(TIUY,TIUDA)^TIUSRVA — one param (note IEN); the user is the
    # session DUZ. Returns "SIGNATURE"/"COSIGNATURE" (empty = no role);
    # mapped to a symbol by the API.
    DataMapper.define(:tiu_which_signature_action) do |m|
      m.rpc "TIU WHICH SIGNATURE ACTION"
      m.scalar :action
    end

    # ========================================================================
    # ORDERS (ORWOR*, ORWORR*)
    # ========================================================================
    # Layouts and formals from FOIA ORWOR.m / ORWORR.m / ORWORR1.m (#220).

    # UNSIGN(LST,ORVP,HAVE) (ORWOR.m:114): ORVP is the patient DFN, the user
    # is the session DUZ (ORWOR.m:116,126). One piece per row, IFN_";"_ACT
    # (ORWOR.m:127); Order.unsigned_for_patient splits the action off.
    DataMapper.define(:orders_unsigned) do |m|
      m.rpc "ORWOR UNSIGN"
      m.field 0, :order_id
    end

    # AGET(REF,DFN,FILTER,GROUPS,DTFROM,DTTHRU,EVENT) (ORWORR.m:25). GET1^ORWORR1
    # writes IFN;ACT^DGrp^ActTm^PtEvtID^EvtName (ORWORR1.m:11) under a .1
    # header TOT^TXTVW^ORYD (ORWORR1.m:13) that Order.list drops. Order text
    # is not in this reply. Piece 1 is read twice: whole as :order_id, and
    # its leading IFN as :ien.
    DataMapper.define(:orders_list) do |m|
      m.rpc "ORWORR AGET"
      m.field 0, :order_id
      m.field 0, :ien, :integer
      m.field 1, :display_group_ien, :integer
      m.field 2, :action_datetime, :fileman_datetime
      m.field 3, :event_ien, :integer
      m.field 4, :event_name
    end

    # ORWOR VWGET and ORWORR GET4LST are referenced in the issue trace
    # alongside AGET. AGET alone is sufficient for the symbolic
    # "list a patient's orders under a filter" contract this module
    # exposes — the two-step VWGET->AGET pattern is a desktop-client
    # optimization that can be added when a real engine consumer needs
    # the cached view spec or per-group detail. Not modeling speculatively.

    # ORWOR RESULT — result text for a single order IEN. Word-processing
    # shape (global array): the gateway returns a multi-line blob.
    DataMapper.define(:order_result) do |m|
      m.rpc "ORWOR RESULT"
      m.text_blob :result_text
    end

    # RESHIST(REF,DFN,ORID,ID) (ORWOR.m:36): the formals of RESULT, and a
    # display report in ^TMP("ORXPND",$J,n,0) (ORWOR.m:42, ORWOR2.m:14) --
    # formatted text, not typed rows.
    DataMapper.define(:order_result_history) do |m|
      m.rpc "ORWOR RESULT HISTORY"
      m.text_blob :history_text
    end

    # ORWOR ACTION TEXT — text describing the user-facing action available
    # on an order (release, sign, discontinue, etc). Takes ORDER_IEN and
    # the action code; returns a free-text blob.
    DataMapper.define(:order_action_text) do |m|
      m.rpc "ORWOR ACTION TEXT"
      m.text_blob :action_text
    end

    # EXPIRED(ORY) (ORWOR.m:147): no parameter; NOW less the ORWOR EXPIRED
    # ORDERS hours, the FileMan date/time to start a search for expired
    # orders from (ORWOR.m:149-150). It says nothing about any one order.
    DataMapper.define(:order_expired) do |m|
      m.rpc "ORWOR EXPIRED"
      m.scalar :search_start, :fileman_datetime
    end

    # SHEETS(LST,ORVP) (ORWOR.m:91): rows "TYPE;ID^label" -- C;O current
    # view, A;<ts> / A;-1 admit, T;<ts> / T;-1 transfer, D;0 discharge
    # (ORWOR.m:97-105). Piece 1 is a composite id, kept whole; Order splits it.
    DataMapper.define(:order_sheets) do |m|
      m.rpc "ORWOR SHEETS"
      m.field 0, :sheet_id
      m.field 1, :label
    end

    # ORWOR TSALL — site-level catalog of order sheets, independent of
    # patient. One row per sheet: IEN^NAME.
    DataMapper.define(:order_sheets_all) do |m|
      m.rpc "ORWOR TSALL"
      m.field 0, :ien, :integer
      m.field 1, :name
    end

    # ========================================================================
    # SYMPTOM CATALOG (ORWDAL32*)
    # ========================================================================

    # ORWDAL32 SYMPTOMS — SYMPTOMS^ORWDAL32 as built (OR*3.0*233; the public
    # FOIA tree still carries the pre-233 tag) answers Y(I)=IEN_U_FROM
    # (ORWDAL32.m:118). Since 233 the walk also indexes each synonym as
    # SYN_$C(9)_"<"_NAME_">"_U_NAME (ORWDAL32.m:109-111), so a synonym row is
    #   IEN ^ SYNONYM<tab><NAME> ^ NAME
    # and a plain row is IEN ^ NAME. There is no SNOMED column; piece 3 is the
    # preferred symptom name, present on synonym rows only (#221).
    DataMapper.define(:symptom_search) do |m|
      m.rpc "ORWDAL32 SYMPTOMS"
      m.field 0, :ien, :integer
      m.field 1, :name
      m.field 2, :preferred_name
    end

    # ORWDAL32 DEF — defaults tree for the allergy-symptom entry UI. Takes
    # no params and returns a typed-tree response: lines starting with "~"
    # are category headers, lines starting with "i" are items belonging to
    # the most recent category and encode (type_code, label) via ^.
    # Example:
    #   ~Reactions
    #   iD^Drug
    #   iF^Food
    # The mapping returns the raw lines; api/symptom.rb parses the tree.
    DataMapper.define(:symptom_defaults) do |m|
      m.rpc "ORWDAL32 DEF"
      m.text_blob :tree_text
    end

    # ========================================================================
    # IMAGING (ORWRA IMAGING*, MAG*)
    # ========================================================================
    # Field positions are best-effort pending wider trace capture.

    DataMapper.define(:image_exams) do |m|
      m.rpc "ORWRA IMAGING EXAMS1"
      m.field 0, :ien, :integer
      m.field 1, :exam_type
      m.field 2, :datetime, :fileman_datetime
      m.field 3, :status
      m.field 4, :modality
      m.field 5, :description
    end

    # ========================================================================
    # ADT / PATIENT MOVEMENT reads (ORWPT — stock VistA over ^DGPM #405)
    # ========================================================================
    #
    # These are the ADT/movement RPCs that actually exist in the #8994 registry.
    # There is NO stock movement-WRITE RPC (admit/transfer/discharge): the BPRM
    # twin's ADT-write scenario (#15) requires a new FileMan-safe (^DIE/DGPMV*)
    # server RPC to be authored — tracked with rpms-ops#366. Parameter/response
    # shapes below are from ORWPT.m (Order Entry) entry points ADMITLST/INPLOC/
    # DISCHRG in FOIA-RPMS.

    # ORWPT ADMITLST — ADMITLST^ORWPT. A patient's admission movements (multi-
    # line). Format: MOVE_DATETIME^HOSP_LOC_IEN^WARD_LOC_NAME^MOVEMENT_TYPE^
    #   MOVEMENT_IEN^TIU_DISCHARGE_SUMMARY_DA. Param: DFN.
    DataMapper.define(:patient_admissions) do |m|
      m.rpc "ORWPT ADMITLST"
      m.field 0, :movement_datetime, :fileman_datetime
      m.field 1, :location_ien,      :integer
      m.field 2, :location
      m.field 3, :movement_type
      m.field 4, :movement_ien,      :integer
      m.field 5, :tiu_document_ien,  :integer
    end

    # ORWPT INPLOC — INPLOC^ORWPT. A patient's current inpatient location
    # (single line). Format: HOSP_LOC_IEN^WARD_NAME^WARD_SYNONYM (WARD
    # LOCATION #42 0-node piece 3). Param: DFN.
    # NB a leading 0 alone does not mean "not admitted": REC starts at 0 and
    # only the HOSP_LOC piece stays 0 when the ward has no 44-node link, so
    # an admitted patient on an unlinked ward is "0^MED WARD^MW"
    # (ORWPT.m:222-227); not-admitted is "0^^". RpmsRpc::Adt.current_location
    # makes the distinction.
    DataMapper.define(:patient_current_location) do |m|
      m.rpc "ORWPT INPLOC"
      m.field 0, :location_ien, :integer
      m.field 1, :ward
      m.field 2, :ward_synonym
    end

    # ORWPT DISCHARGE — DISCHRG^ORWPT. Discharge date/time for the admission
    # identified by (DFN, ADMIT_DATETIME). Params: DFN^ADMIT_DATETIME.
    # Scalar kept as :string — the routine returns bare DT (today, date-only)
    # on every miss (ORWPT.m:205,207), so RpmsRpc::Adt.discharge_datetime
    # must see the raw value to treat date-only replies as the no-data
    # sentinel rather than a discharge at midnight today.
    DataMapper.define(:patient_discharge) do |m|
      m.rpc "ORWPT DISCHARGE"
      m.scalar :discharge_datetime, :string
    end

    # ========================================================================
    # REGISTRATION + GENERIC FILEMAN CRUD (VAFC VOA / DDR*)
    # ========================================================================
    #
    # Stock-VistA RPCs used by the composed patient-registration flow
    # (RpmsRpc::Registration) and the FileMan Delphi Components wrapper
    # (RpmsRpc::DdrFileman). Every wire shape below is cited to the M
    # routine serving the RPC in the bcer-9.0-ydb corpus
    # (rpms-ops/data/standup/bcer-9.0-ydb/r/); tag^routine bindings are from
    # the live #8994 REMOTE PROCEDURE dump (.broker_dumps_8994_20260607.txt):
    #
    #   VAFC VOA ADD PATIENT  → ADD^VAFCPTAD    (return type 2 = ARRAY)
    #   DDR LISTER            → LISTC^DDR       (return type 4 = GLOBAL ARRAY)
    #   DDR LOCK/UNLOCK NODE  → LOCKC^DDR1      (return type 1 = SINGLE VALUE)
    #   DDR GETS ENTRY DATA   → GETSC^DDR2      (return type 2)
    #   DDR FILER             → FILEC^DDR3      (return type 2)
    #   DDR VALIDATOR         → VALC^DDR3       (return type 2)
    #   DDR KEY VALIDATOR     → KEYVAL^DDR3 as registered; the code is
    #                           KEYVAL^DDR4 (return type 2)
    #
    # All take LIST params (named or numeric subscripts) — see
    # CiaClient#call_rpc_raw for the {CIA} wire encoding of subscripted
    # params (CIANBLIS.m, DOACTION lines 128-134).

    # VAFC VOA ADD PATIENT — adds a PATIENT (#2) record. One list param
    # (PARAM) with named subscripts PRFCLTY/NAME/GENDER/DOB/SSN/SRVCNCTD/
    # TYPE/VET/FULLICN [+ POBCTY/POBST/MMN/ALIAS] (VAFCPTAD.m:10-25).
    # Reply RETURN(1):
    #   "-1^error text"          — add failed        (VAFCPTAD.m:28,140)
    #   "1^DFN"                  — added, or the ICN already exists at this
    #                              facility (idempotent: VAFCPTAD.m:29,55,145)
    #   "1^DFN^ALIAS warning..." — added; ALIAS multiple failed
    #                              (ALIAS^VAFCPTAD: VAFCPTAD.m:178)
    DataMapper.define(:voa_add_patient) do |m|
      m.rpc "VAFC VOA ADD PATIENT"
      m.status_reply! # "-1^error text" is the modeled rejection record
      m.field 0, :status, :integer
      m.field 1, :dfn_or_error
      m.field 2, :warning
    end

    # DDR LISTER — LIST^DIC projection. One list param with subscripts
    # FILE/IENS/FIELDS/FLAGS/MAX/FROM/PART/XREF/SCREEN/ID/OPTIONS
    # (PARSE^DDR: DDR.m:53-65). Multi-line reply parsed by
    # DdrFileman.lister ("[Misc]"/"MORE^..", "[Data]", packed rows,
    # "[Errors]" — V0^DDR: DDR.m:21-30).
    DataMapper.define(:ddr_lister) do |m|
      m.rpc "DDR LISTER"
      m.text_blob :lines
    end

    # DDR LOCK/UNLOCK NODE — incremental M LOCK on a global node. One list
    # param: NODE, LOCKMODE (truthy = lock, absent = unlock), TIMEOUT
    # (default 5s). Reply DDROK: "1" acquired/released, "0" timed out
    # (LOCKC^DDR1: DDR1.m:18-30).
    DataMapper.define(:ddr_lock_unlock_node) do |m|
      m.rpc "DDR LOCK/UNLOCK NODE"
      m.scalar :ok, :boolean
    end

    # DDR GETS ENTRY DATA — GETS^DIQ projection. One list param with
    # subscripts FILE/IENS/FIELDS/FLAGS[/OPTIONS] (PARSE^DDR2:
    # DDR2.m:113-121). Multi-line reply parsed by DdrFileman.gets_entry
    # (default no-OPTIONS format: "[Data]" +
    # "FILE^IEN^FIELD^INTERNAL^EXTERNAL" rows / "[ERROR]" — GETSC^DDR2:
    # DDR2.m:22-43,61).
    DataMapper.define(:ddr_gets_entry_data) do |m|
      m.rpc "DDR GETS ENTRY DATA"
      m.text_blob :lines
    end

    # DDR FILER — UPDATE^DIE ("ADD" mode) / FILE^DIE (other modes) filer.
    # Params: MODE literal, DDRROOT list of "FILE^FIELD^IENS^VALUE" rows,
    # FLAGS literal, DDRIENS list pinning placeholder IENs
    # (FILEC^DDR3: DDR3.m:7-24; FDASET^DDR3: DDR3.m:26-35). Multi-line
    # reply parsed by DdrFileman.filer ("[Data]" + "+n,^IEN" rows /
    # "[BEGIN_diERRORS]" block — DDR3.m:19-23,63-79).
    DataMapper.define(:ddr_filer) do |m|
      m.rpc "DDR FILER"
      m.text_blob :lines
    end

    # DDR VALIDATOR — VAL^DIE for one field value. One list param with
    # subscripts FILE/IENS/FIELD/VALUE (VALC^DDR3: DDR3.m:37-44).
    # Multi-line reply parsed by DdrFileman.validate_field ("[FILLER]",
    # "[Data]", internal result — "^" when invalid — then the external
    # form: DDR3.m:45-50).
    DataMapper.define(:ddr_validator) do |m|
      m.rpc "DDR VALIDATOR"
      m.text_blob :lines
    end

    # DDR KEY VALIDATOR — $$KEYVAL^DIEVK over an FDA built from one list
    # param of alternating "FILE^IENS^FIELD" / value rows (KEYVAL^DDR4 +
    # FDASET2^DDR4: DDR4.m:4-19). Reply DDROUT(1) = "1" | "0", parsed by
    # DdrFileman.validate_key. #8994 on bcer-9.0 names KEYVAL^DDR3, which
    # does not exist: the live call answers %YDB-E-LABELMISSING.
    DataMapper.define(:ddr_key_validator) do |m|
      m.rpc "DDR KEY VALIDATOR"
      m.text_blob :lines
    end
  end
end
