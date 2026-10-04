# frozen_string_literal: true

require_relative "../data_mapper"

# IHS/RPMS-specific RPC response mappings (B* namespaces, CIAV*).
# These exist only on RPMS installs and stay in rpms-rpc after the
# vista-rpc extraction; registers into the same DataMapper registry as
# mappings/stock_vista.rb. Loaded via `require "rpms_rpc/mappings"` —
# see ../mappings.rb.
module RpmsRpc
  module Mappings
    # ========================================================================
    # PATIENT (BEHOPT*, BEHOVM*)
    # ========================================================================

    # BEHOPTCX PTINFO — broad patient identity bundle for chart banner
    # Format: NAME^SEX^DOB^SSN^^^^^^^MRN^^^^^^DESIGNATED_TEAM^PRIMARY_PROVIDER^^
    DataMapper.define(:patient_ptinfo) do |m|
      m.rpc "BEHOPTCX PTINFO"
      m.field 0,  :name
      m.field 1,  :sex
      m.field 2,  :dob_raw
      m.field 3,  :ssn
      m.field 10, :mrn
      m.field 16, :designated_team
      m.field 17, :primary_provider
    end

    # BEHOPTPC GETBDP — designated primary provider detail
    # Format: LABEL^PROVIDER_NAME^PROVIDER_IEN^TITLE^DATE
    DataMapper.define(:patient_designated_provider) do |m|
      m.rpc "BEHOPTPC GETBDP"
      m.field 0, :label
      m.field 1, :provider_name
      m.field 2, :provider_ien, :integer
      m.field 3, :title
      m.field 4, :date_raw
    end

    # BEHOCACV CWAD — patient CWAD flags (scalar). Each letter present in
    # the response indicates: C=Crises, W=Warnings, A=Allergies, D=Advance
    # Directives. Empty string means none.
    DataMapper.define(:patient_cwad) do |m|
      m.rpc "BEHOCACV CWAD"
      m.scalar :cwad
    end

    # BEHOVM TEMPLATE — vital field definitions for a location (multi-line)
    # Format per line: IEN^DISPLAY_ORDER^NAME^ABBREV^UNITS^LOW^HIGH^PERCENTILE_RPC^REQUIRED^DISPLAY_ROW
    DataMapper.define(:vital_template) do |m|
      m.rpc "BEHOVM TEMPLATE"
      m.field 0, :ien,            :integer
      m.field 1, :display_order,  :integer
      m.field 2, :name
      m.field 3, :abbreviation
      m.field 4, :units
      m.field 5, :low,            :integer
      m.field 6, :high,           :integer
      m.field 7, :percentile_rpc
      m.field 8, :required,       :integer
      m.field 9, :display_row,    :integer
    end

    # BEHOVM VALIDATE — server-side vital value validation (scalar)
    # Returns echoed value when valid, error marker string otherwise.
    DataMapper.define(:vital_validate) do |m|
      m.rpc "BEHOVM VALIDATE"
      m.scalar :validated_value
    end

    # BEHOVM SAVE — bulk vital save (scalar)
    # Returns "0" for success; non-zero/non-empty for error.
    DataMapper.define(:vital_save) do |m|
      m.rpc "BEHOVM SAVE"
      m.scalar :result_code
    end

    # The invented placeholder RPC family that used to sit here is fully
    # removed (docs/RPC_COVERAGE.md provenance notes). The paths it claimed
    # to cover run on verified RPCs instead:
    #   - tribal / service-unit reads → DDR GETS ENTRY DATA, DDR LISTER,
    #     DDR VALIDATOR over the real files (#9000001 IHS PATIENT, TRIBE
    #     #9999999.03, SERVICE UNIT #9999999.22) — RpmsRpc::Tribal
    #   - patient registration        → VAFC VOA ADD PATIENT + DDR FILER —
    #     RpmsRpc::Registration.register
    #   - patient update              → DDR FILER (FILE^DIE) —
    #     RpmsRpc::Registration.update
    #   - visit get-or-create         → BEHOENCX FETCH with the CREATE flag
    #     (:encounter_fetch below) — RpmsRpc::Encounter.create

    # BGOVMSR GET — every V MEASUREMENT on one visit (multi-line).
    # One INP param: "VISIT_IEN^FORMAT" — format 0 = one row per
    # measurement (GET^BGOVMSR: BGOVMSR.m:41-77):
    #   TYPE[1]^VALUE[2]^DATE_DISPLAY[3]^MEASUREMENT_IEN[4]^VISIT_IEN[5]^
    #   PROVIDER_NAME[6]^LOCKED[7]
    # TYPE is the ^AUTTMSR .01 abbreviation ("WT"); VALUE is the raw stored
    # ^AUPNVMSR 0-node piece 4 in US units — GET's own single-string branch
    # converts WT lb→kg, HT in→cm, TMP F→C (BGOVMSR.m:60-63). DATE_DISPLAY
    # is CDT display text ("JUN 07, 2026@14:30" — CDT^BGOVMSR:
    # BGOVMSR.m:79-86), not a FileMan date; the internal date rides fields
    # 1201/.07 of #9000010.01 (see Measurement.for_visit). NB: unlike the
    # BEHOVM query path (BLDXRF^BEHOVM drops rows with field 2 set),
    # GET^BGOVMSR does NOT filter entered-in-error rows — callers must
    # check the flag themselves.
    DataMapper.define(:visit_measurements) do |m|
      m.rpc "BGOVMSR GET"
      m.field 0, :type
      m.field 1, :value
      m.field 2, :date_display
      m.field 3, :measurement_ien, :integer
      m.field 4, :visit_ien,       :integer
      m.field 5, :provider_name
      m.field 6, :locked,          :boolean
    end

    # BGOVMSR LAST — most recent V MEASUREMENT per type (multi-line).
    # One INP param: "DFN^TYPE_LIST^VISIT_IEN" — TYPE_LIST is ";"-separated
    # abbreviations, server default "HT;WT;TMP;BP;PU;RS;PA"; VISIT_IEN
    # restricts to one visit (LAST^BGOVMSR: BGOVMSR.m:3-35). Row format
    # (BGOVMSR.m:35):
    #   TYPE[1]^VALUE[2]^DATE_DISPLAY[3]^MEASUREMENT_IEN[4]^VISIT_IEN[5]^LOCKED[6]
    # Same caveats as :visit_measurements (US-unit raw value, display
    # date, no entered-in-error filter).
    DataMapper.define(:latest_measurements) do |m|
      m.rpc "BGOVMSR LAST"
      m.field 0, :type
      m.field 1, :value
      m.field 2, :date_display
      m.field 3, :measurement_ien, :integer
      m.field 4, :visit_ien,       :integer
      m.field 5, :locked,          :boolean
    end

    # BEHOVM2 VUNITS — units + normal range for one vital type, keyed by
    # the type name/abbreviation (same ^BEHOVM(90460.01,"B",...) lookup
    # the production GETCATS^BEHOVM2 call path uses — BEHOVM.m QUERY
    # passes VABR). Reply: "US unit^LO^HI^Metric unit^LO^HI"
    # (VUNITS^BEHOVM2: BEHOVM2.m:186-196 → UNITS^BEHOVM). Unknown type →
    # empty reply (RET stays "").
    DataMapper.define(:vital_units) do |m|
      m.rpc "BEHOVM2 VUNITS"
      m.field 0, :us_unit
      m.field 1, :us_low
      m.field 2, :us_high
      m.field 3, :metric_unit
      m.field 4, :metric_low
      m.field 5, :metric_high
    end

    # ========================================================================
    # SERVICE REQUESTS / REFERRALS (BMC*)
    # ========================================================================

    # BMC SEARCH REFERRAL — referral search (multi-line)
    # Format: IEN^PATIENT_DFN^STATUS^TYPE^DATE^PROVIDER
    # Verified on staging file 8994 (2026-06-07): NAME is
    # "BMC SEARCH REFERRAL", tag SRCHREF, routine BMCRPC1.
    DataMapper.define(:referral_search) do |m|
      m.rpc "BMC SEARCH REFERRAL"
      m.field 0, :ien
      m.field 1, :patient_dfn, :integer
      m.field 2, :status
      m.field 3, :type
      m.field 4, :date,     :fileman_date
      m.field 5, :provider
    end

    # BMC ADD C32 PRINT LOG — records health-summary print activity.
    DataMapper.define(:bmc_add_c32_print_log) do |m|
      m.rpc "BMC ADD C32 PRINT LOG"
      m.scalar :result
    end

    # BMC ADD REFERRAL — creates a primary CHS/RCIS referral.
    DataMapper.define(:bmc_add_referral) do |m|
      m.rpc "BMC ADD REFERRAL"
      m.scalar :result
    end

    # BMC CHK YEAR SITE PARAM — validates fiscal-year/site RCIS setup.
    DataMapper.define(:bmc_check_year_site_param) do |m|
      m.rpc "BMC CHK YEAR SITE PARAM"
      m.scalar :result
    end

    # BMC CONSULTATION STATUS UPDATE — updates the linked consultation status.
    DataMapper.define(:bmc_consultation_status_update) do |m|
      m.rpc "BMC CONSULTATION STATUS UPDATE"
      m.scalar :result
    end

    # BMC GET PURPOSE OF REF API — referral purpose lookup.
    # Common shape: IEN^NAME^CODE; extra pieces remain available through raw RPC calls.
    DataMapper.define(:bmc_purpose_of_referral_list) do |m|
      m.rpc "BMC GET PURPOSE OF REF API"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :code
    end

    # BMC GET RCIS TEMPLATE DETAIL — template detail text/lines.
    DataMapper.define(:bmc_rcis_template_detail) do |m|
      m.rpc "BMC GET RCIS TEMPLATE DETAIL"
      m.text_blob :detail
    end

    # BMC GET RCIS TEMPLATE LIST — RCIS template lookup.
    # Common shape: IEN^NAME^TYPE.
    DataMapper.define(:bmc_rcis_template_list) do |m|
      m.rpc "BMC GET RCIS TEMPLATE LIST"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :type
    end

    # BMC GET REFERENCE DATA — RCIS reference-data lookup.
    # Common shape: IEN^NAME^CODE.
    DataMapper.define(:bmc_reference_data) do |m|
      m.rpc "BMC GET REFERENCE DATA"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :code
    end

    # BMC GET USERS/PROVIDERS — PROV^BMCRPC4(.Y,ISPROV): one node,
    # "-1^All~IEN^NAME~IEN^NAME~..." (BMCRPC4.m:136-141); Referral#users_providers
    # splits it with RcisWire.records.
    DataMapper.define(:bmc_users_providers) do |m|
      m.rpc "BMC GET USERS/PROVIDERS"
      m.text_blob :providers
    end

    # BMC HEALTH SUMMARY TYPE — health-summary type lookup.
    # Common shape: IEN^NAME^ABBREVIATION.
    DataMapper.define(:bmc_health_summary_type) do |m|
      m.rpc "BMC HEALTH SUMMARY TYPE"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :abbreviation
    end

    # BMC PATIENT ELIGIBILITY STATUS — GTPTELST^BMCRPC4 (BMCRPC4.m:129):
    # ELIGIBILITY STATUS (#9000001 field 1112, external) ^ preferred name.
    DataMapper.define(:bmc_patient_eligibility_status) do |m|
      m.rpc "BMC PATIENT ELIGIBILITY STATUS"
      m.field 0, :status
      m.field 1, :preferred_name
    end

    # BMC PATIENT FACE SHEET — patient context text/lines.
    DataMapper.define(:bmc_patient_face_sheet) do |m|
      m.rpc "BMC PATIENT FACE SHEET"
      m.text_blob :face_sheet
    end

    # BMC PATIENT HEALTH SUMMARY — patient health-summary text/lines.
    DataMapper.define(:bmc_patient_health_summary) do |m|
      m.rpc "BMC PATIENT HEALTH SUMMARY"
      m.text_blob :health_summary
    end

    # BMC PRINT REFERRAL — print operation result.
    DataMapper.define(:bmc_print_referral) do |m|
      m.rpc "BMC PRINT REFERRAL"
      m.scalar :result
    end

    # BMC PROVIDERS — provider lookup.
    # Common shape: DUZ^NAME^TITLE.
    DataMapper.define(:bmc_providers) do |m|
      m.rpc "BMC PROVIDERS"
      m.field 0, :duz
      m.field 1, :name
      m.field 2, :title
    end

    # BMC REFERRAL STATUS UPDATE — updates the referral status.
    DataMapper.define(:bmc_referral_status_update) do |m|
      m.rpc "BMC REFERRAL STATUS UPDATE"
      m.scalar :result
    end

    # BMC SEARCH REFERRED TO — referred-to facility/provider lookup.
    # Common shape: IEN^NAME^TYPE.
    DataMapper.define(:bmc_search_referred_to) do |m|
      m.rpc "BMC SEARCH REFERRED TO"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :type
    end

    # BMC UPDATE REFERRAL — updates an existing CHS/RCIS referral.
    DataMapper.define(:bmc_update_referral) do |m|
      m.rpc "BMC UPDATE REFERRAL"
      m.scalar :result
    end

    # ========================================================================
    # REFERRAL DETAIL (BMC*)
    # ========================================================================

    # BMC GET REFERRAL — single referral detail
    # Verified on staging file 8994 (2026-06-07): NAME is
    # "BMC GET REFERRAL", tag GTRFBYID, routine BMCRPC1.
    DataMapper.define(:referral_detail) do |m|
      m.rpc "BMC GET REFERRAL"
      m.field 0, :ien
      m.field 1, :patient_dfn, :integer
      m.field 2, :status
      m.field 3, :type
      m.field 4, :date,     :fileman_date
      m.field 5, :provider
      m.field 6, :facility
      m.field 7, :notes
    end

    # ========================================================================
    # ENCOUNTERS / VISITS (BEHOENCX*)
    # ========================================================================

    # BEHOENCX GETVISIT(DATA,IEN) — one visit by VISIT file IEN.
    # GETVISIT^BEHOENCX (BEHOENCX.m:5,8-15): LOOKUP^VSIT(IEN,"I",0) fills
    # VSIT(field) and line 13 emits VSIT("LOC","VDT","SVC","PAT","VID") in
    # that order, then line 14 appends $$ISLOCKED(IEN):
    #   LOC^VDT^SVC^PAT^VID^LOCKED
    # Those are VISIT #9000010 fields .22 HOSPITAL LOCATION, .01 VISIT/ADMIT
    # DATE&TIME, .07 SERVICE CATEGORY, .05 PATIENT NAME, 15001 VISIT ID
    # (FLD^VSITFLD: VSITFLD.m:15-33). Empty when the IEN is not a visit or
    # the visit is DELETED (lines 11-12).
    # Piece 3 is a service category ("A" ambulatory, "I" in-hospital, ...),
    # not an encounter status, and piece 5 is the visit id, not a ward —
    # the :status / :ward labels that sat there were never on this wire
    # (#211). Live capture: test/fixtures/wire_captures/behoencx-getvisit.yml.
    DataMapper.define(:encounter_visit) do |m|
      m.rpc "BEHOENCX GETVISIT"
      m.field 0, :location_ien,     :integer
      m.field 1, :datetime_raw
      m.field 2, :service_category
      m.field 3, :patient_dfn,      :integer
      m.field 4, :visit_id
      m.field 5, :locked,           :boolean
    end

    # BEHOENCX FETCH(DATA,DFN,VSTR,PRV,CREATE) — resolve (and optionally
    # create) a visit from a visit string, returning its context. The ONE
    # mapping for this RPC (#213): Encounter.open sends CREATE=0 (a read),
    # Encounter.create sends CREATE=1/-1 (the visit-create path).
    # Params positionally (FETCH^BEHOENCX: BEHOENCX.m:32; registry formals
    # DATA,DFN,VSTR,PRV,CREATE): DFN; VSTR "LOC;FM_DATETIME;SVC_CAT[;VISITIEN]"
    # — with the 4th piece VSTR2VIS uses that IEN and never searches
    # (BEHOENCX.m:107-111), without it FNDVIS searches a 60-minute window
    # (lines 64-94); PRV (provider IEN, optional — line 36 defaults it to DUZ
    # when the user is a provider); CREATE (-1 always create, 0 never — FNDVIS
    # sets IN("NEVER ADD"), line 80 — 1 create if not found). Creation descends
    # to GETVISIT^BSDAPI4 / GETVISIT^BEHOENC1 (lines 82-84), the IHS PCC
    # visit API; GETVISIT^BEHOENCX itself never creates.
    # Reply (header lines 30-31; built at lines 41-46):
    #   LOCNAME^LOCABBR^ROOMBED^PROVIEN^PROVNAME^VISITIEN^VISITID^LOCKED^ERRORTXT
    # 1-2 = ^SC(LOC,0) pieces 1-2; 3 = ^DPT(DFN,.101) room-bed; 4 = PRV;
    # 5 = ^VA(200,PRV,0) piece 1; 6-8 only when the visit resolved (IEN>0);
    # 9 only when it did not ("-1^text" from FNDVIS or VIS2VSTR, lines 85
    # and 117-118). There is no location IEN and no ward on this wire.
    # Live capture (CREATE=0): test/fixtures/wire_captures/behoencx-fetch.yml.
    DataMapper.define(:encounter_fetch) do |m|
      m.rpc "BEHOENCX FETCH"
      m.field 0, :location_name
      m.field 1, :location_abbrev
      m.field 2, :room_bed
      m.field 3, :provider_ien,  :integer
      m.field 4, :provider_name
      m.field 5, :visit_ien,     :integer
      m.field 6, :visit_id
      m.field 7, :locked,        :boolean
      m.field 8, :error
    end

    # BEHOENCX CHKVISIT — missing-component report (multi-line)
    # Format per line: COMPONENT^MESSAGE
    DataMapper.define(:encounter_chkvisit) do |m|
      m.rpc "BEHOENCX CHKVISIT"
      m.field 0, :component
      m.field 1, :message
    end

    # ========================================================================
    # PHR / CCD (BEHOCCD*, BEHOCIR*)
    # ========================================================================

    # BEHOCIR1 GETCCDS — CCD documents for patient
    # Format per line: IEN^DATE^SOURCE^TITLE^TYPE
    DataMapper.define(:ccd_document) do |m|
      m.rpc "BEHOCIR1 GETCCDS"
      m.field 0, :ien, :integer
      m.field 1, :date, :fileman_date
      m.field 2, :source
      m.field 3, :title
      m.field 4, :type
    end

    # BEHOCCD GETREF — referrals with CCD status
    # Format per line: REFERRAL_IEN^VISIT_IEN^HAS_CCD^CCD_SENT_DATE^PROVIDER^FACILITY
    DataMapper.define(:ccd_referral) do |m|
      m.rpc "BEHOCCD GETREF"
      m.field 0, :referral_ien, :integer
      m.field 1, :visit_ien, :integer
      m.field 2, :has_ccd, :boolean
      m.field 3, :ccd_sent_date, :fileman_date
      m.field 4, :provider_name
      m.field 5, :facility
    end

    # BEHOCIR GETTXT — CCD document content
    DataMapper.define(:immunization_text) do |m|
      m.rpc "BEHOCIR GETTXT"
      m.text_blob :content
    end

    # BEHOCIR GETNUM — CCD count and reconciliation status
    # Format: TOTAL^RECONCILED
    DataMapper.define(:immunization_count) do |m|
      m.rpc "BEHOCIR GETNUM"
      m.field 0, :total, :integer
      m.field 1, :reconciled, :integer
    end

    # BEHOCCD PHR — PHR enrollment/access check
    DataMapper.define(:phr_access) do |m|
      m.rpc "BEHOCCD PHR"
      m.field 0, :has_access, :boolean
      m.field 1, :message
    end

    # ========================================================================
    # SESSION BOOTSTRAP (CIAVMCFG*, CIAVCXUS*)
    # ========================================================================
    #
    # CIAVMRPC GETPAR is deliberately NOT mapped (#239). It fetched the
    # VueCentric client's own config root ("CIAVM DEFAULT SOURCE"), the path
    # the Windows shell loads its component registry from: tier V, legacy
    # under ADR 0004 (reads client session/widget state). A frontend-agnostic
    # consumer has no CIAVM config root. Its other use, reading site
    # parameters such as BGO CC PREFIX TEXT, is site configuration that
    # belongs in the captured L2/L3 overlay, not in an RPC round-trip.

    # CIAVMCFG GETREG — fetch the launching client's registry settings.
    # Field positions are best-effort pending wider trace capture; the RPC
    # returns the registry/config root path used to locate cached config.
    DataMapper.define(:session_registry) do |m|
      m.rpc "CIAVMCFG GETREG"
      m.field 0, :root
    end

    # CIAVCXUS VIMINFO — VIMINFO^CIAVCXUS. One row, documented by the routine
    # (CIAVCXUS.m:20-21) and built at CIAVCXUS.m:25-31:
    #   DUZ ^ NAME ^ PTMOUT;STMOUT;CNTDN ^ COMPOSE MODE ^ DESIGN MODE
    # Piece 3 holds the CIAVM PRIMARY/SECONDARY TIMEOUT and COUNTDOWN INTERVAL
    # parameters joined by ";"; pieces 4-5 are $$HASKEY of CIAV COMPOSE and
    # CIAV DESIGN (1/0). It carries no site: an unknown user answers "" (#221).
    DataMapper.define(:session_vim_info) do |m|
      m.rpc "CIAVCXUS VIMINFO"
      m.field 0, :duz, :integer
      m.field 1, :user_name
      m.field 2, :timeouts
      m.field 3, :compose_mode, :boolean
      m.field 4, :design_mode, :boolean
    end

    # ========================================================================
    # SITE / DIVISION CONTEXT (BEHOSICX*)
    # ========================================================================

    # BEHOSICX SITEINFO — the authenticated user's current site. The RPC
    # takes no params and returns a single site across 11 response lines
    # (not multi-record, not caret-delimited). Live shape:
    #   [0]  "RPMS.MEDSPHERE.COM"   → domain
    #   [1]  "DEMO IHS CLINIC"      → name
    #   [2]  "8904"                 → abbreviation
    #   [3]  "ILLINOIS"             → state
    #   [4]  ""                     → (reserved)
    #   [5]  "123 ELM STREET"       → address
    #   [6]  ""                     → (reserved)
    #   [7]  "ANYWHERE"             → city
    #   [8]  "99999"                → zip
    #   [9]  "7819"                 → ien
    #   [10] (unknown, ignored)
    DataMapper.define(:site_info) do |m|
      m.rpc "BEHOSICX SITEINFO"
      m.line_field 0, :domain
      m.line_field 1, :name
      m.line_field 2, :abbreviation
      m.line_field 3, :state
      m.line_field 5, :address
      m.line_field 7, :city
      m.line_field 8, :zip
      m.line_field 9, :ien, :integer
    end

    # ========================================================================
    # PROBLEM LIST WRITE PATHS (BGOPROB*)
    # ========================================================================

    # BGOPROB SET — SET^BGOPROB (BGOPROB.m:225), the IPL problem writer.
    # Broker formals after RET: DFN, PRIEN (empty = new), VIEN, ARRAY (list
    # param of "P"/"A"/"Q" lines — BGOPROB.m:218-222,232-236), SPEC, PIP.
    # Returns the problem IEN on success (BGOPROB.m:322) or -CODE^text via
    # ERR^BGOUTL (BGOUTL.m:408-409): -1001 unknown patient (:268), -1048
    # unresolvable ICD (:273), -1049 missing location (:276).
    # (The former binding here, BGOPROB1 EDPROB, is a READ — "Get active
    # problems for a patient" — and silently ignored write payloads: #217.)
    DataMapper.define(:problem_set) do |m|
      m.rpc "BGOPROB SET"
      m.scalar :result
    end

    # BGOPROB DEL — DEL^BGOPROB (BGOPROB.m:210) → DEL^BGOPROB3. One param:
    # Problem IEN ^ TYPE ^ DELETE REASON ^ COMMENT ^ PROB ID (BGOPROB.m:209;
    # REASON/COMMENT are pieces 3/4 in DEL^BGOPROB3). Logical delete: sets
    # status "D" plus deletion audit fields. Returns "" on success.
    DataMapper.define(:problem_remove) do |m|
      m.rpc "BGOPROB DEL"
      m.scalar :result
    end

    # BGOPROB GET CLASS — RETIRED, never bound. The #8994 registry sends
    # this name to DICLASS^BGOASLK (.broker_dumps_8994_20260607.txt:3103
    # "BGOPROB GET CLASS^DICLASS^BGOASLK^2"), which is "Get the
    # classifications for an asthma DX" (BGOASLK.m:52-67): ONE param
    # "ICD ^ SNOMED ^ class type" (BGOASLK.m:53), "" unless $$CHECK^BGOASLK
    # says the dx is asthma (BGOASLK.m:58-60), and TWO-piece rows out of
    # ^APCDPLCL (BGOASLK.m:65). It is not a problem list and takes no DFN.
    # The former :problem_filter mapping declared a ten-piece ORQQPL row
    # over it and Problem.filter called it with (DFN, scope_code) — an
    # invented capability of the same class as the retired BHDPTRPC family
    # (#174/#184). Rebind it deliberately, as an asthma-classification read,
    # if a caller ever needs one.

    # ========================================================================
    # VISIT DATA ENTRY WRITES (BGOVPOV*, BGOVHF*, BGOVEXAM*, BGOVMSR*, BGOVCPT*)
    # ========================================================================
    # Each visit-data type has its own SET RPC. (BGOVUPD SET, the former
    # shared binding, writes V UPDATE/REVIEWED #9000010.54 only — #217.)
    # All four return the saved V-file IEN on success or -CODE^text via
    # ERR^BGOUTL; visit validation errors come from CHKVISIT^BGOUTL
    # (-1002 no visit / -1003 unknown visit — BGOUTL.m:283-284).

    # BGOVPOV SET — SET^BGOVPOV (BGOVPOV.m:291). Formals after RET:
    # INP, QUAL, INJ, NORM, SPEC. INP (BGOVPOV.m:285-286, parsed :298-303):
    #   VPOV IEN[1] ^ Visit IEN[2] ^ Problem IEN[3] ^ Patient IEN[4] ^
    #   Prov Text[5] ^ Descriptive CT[6] ^ SNOMED CT[7] ^ ICD code[8] ^
    #   Primary/Secondary[9] ^ Provider IEN[10] ^ asthma control[11] ^
    #   norm/abn[12] ^ laterality[13] ^ fracture[14]
    # INJ (BGOVPOV.m:288): Cause DX[1]^Injury Code[2]^Injury Place[3]^
    #   First/Revisit[4]^Injury Dt[5]^Onset Date[6]
    DataMapper.define(:pov_set) do |m|
      m.rpc "BGOVPOV SET"
      m.scalar :result
    end

    # BGOVHF SET — SET^BGOVHF (BGOVHF.m:45). One INP param (BGOVHF.m:44,
    # parsed :48-56,:68):
    #   HF Type IEN[1] ^ V File IEN[2] ^ Visit IEN[3] ^ Severity[4] ^
    #   Provider IEN[5] ^ Quantity[6] ^ Comment[7] ^ Event dt[8]
    DataMapper.define(:health_factor_set) do |m|
      m.rpc "BGOVHF SET"
      m.scalar :result
    end

    # BGOVEXAM SET — SET^BGOVEXAM (BGOVEXAM.m:106). One INP param
    # (BGOVEXAM.m:103-104, parsed :109-129):
    #   V Exam IEN[1] ^ Exam IEN[2] ^ Visit IEN[3] ^ Provider IEN[4] ^
    #   Result[5] ^ Comment[6] ^ Event Date[7] ^ Location IEN[8] ^
    #   Other Location[9] ^ Historical Flag[10] ^ DFN[11]
    DataMapper.define(:exam_set) do |m|
      m.rpc "BGOVEXAM SET"
      m.scalar :result
    end

    # BGOVMSR SET — SET^BGOVMSR (BGOVMSR.m:105). One INP param
    # (BGOVMSR.m:104, parsed :108-118):
    #   Visit IEN[1] ^ V File IEN[2] ^ Type[3] ^ Value[4] ^ Date/Time[5]
    # Type accepts the AUTTMSR abbreviation — non-numeric values go through
    # the "B" cross-reference (BGOVMSR.m:115). There is NO units piece:
    # units are fixed by the measurement type (file 9999999.07).
    DataMapper.define(:measurement_set) do |m|
      m.rpc "BGOVMSR SET"
      m.scalar :result
    end

    # BGOVCPT SET — visit CPT-code save. Returns the saved IEN on success.
    DataMapper.define(:procedure_save) do |m|
      m.rpc "BGOVCPT SET"
      m.scalar :result
    end

    # ========================================================================
    # PERSONAL REFUSALS (BGOREF*)
    # ========================================================================
    # BGOREF is the REFUSAL component — despite the name it does NOT write
    # referrals (#217; referral creation is BMC ADD REFERRAL, see
    # RpmsRpc::Referral.add).

    # BGOREF SET — SET^BGOREF (BGOREF.m:8), files ^AUPNPREF (#9000022) via
    # $$REFSET2^BGOUTL2 (BGOREF.m:29). One INP param (BGOREF.m:4-5, parsed
    # :11-20):
    #   Refusal IEN[1] ^ Refusal Type[2] ^ Item IEN[3] ^ Patient IEN[4] ^
    #   Refusal Date[5] ^ Comment[6] ^ Provider IEN[7] ^ Reason[8]
    # Refusal Type is a REFUSAL TYPE (#9999999.73) name, e.g. "IMMUNIZATION"
    # (BGOUTL2.m:76; BGOVIMM2.m:100); Reason is a REFUSAL REASON
    # (#9999999.102) IEN (BGOREF.m:26-27). Returns "" on success
    # (BGOUTL2.m:126-129) or -CODE^text (-1050/-1001 bad patient —
    # BGOREF.m:12-13).
    DataMapper.define(:refusal_set) do |m|
      m.rpc "BGOREF SET"
      m.scalar :result
    end

    # BGOREF GETREA — GETREA^BGOREF (BGOREF.m:62): SNOMED refusal reasons
    # for a refusal type name (defaults "IMMUNIZATION" — BGOREF.m:67).
    # Rows: IEN[1] ^ TEXT[2] (BGOREF.m:61).
    DataMapper.define(:refusal_reasons) do |m|
      m.rpc "BGOREF GETREA"
      m.field 0, :ien
      m.field 1, :text
    end

    # ========================================================================
    # NOTIFICATIONS / ALERTS (BQI*)
    # ========================================================================
    # Field positions are best-effort pending wider trace capture.

    DataMapper.define(:notifications_inbox) do |m|
      m.rpc "BQI GET COMM ALERTS SPLASH"
      m.field 0, :id, :integer
      m.field 1, :type
      m.field 2, :patient_dfn, :integer
      m.field 3, :message
      m.field 4, :severity
      m.field 5, :created_at, :fileman_datetime
      m.field 6, :read_at, :fileman_datetime
    end

    # NOTE: immunization refusals file through BGOREF SET (:refusal_set)
    # with type "IMMUNIZATION". The former :immunization_refusal_save
    # binding, BGOREP SET, writes REPRODUCTIVE FACTORS (^AUPNREP —
    # BGOREP.m:62-87; it errors on male patients at :86) and is not
    # modeled here (#217).

    # ========================================================================
    # CLINICAL REMINDERS (BGOTRG*, ORQQPX*)
    # ========================================================================

    # BGOTRG GETSUM — reminder summary for a (patient_dfn, visit_ien).
    # Multi-line response; each line one reminder.
    # Field positions are best-effort pending wider trace capture.
    # ORQQPX NEW REMINDERS ACTIVE and ORQQPXRM REMINDERS APPLICABLE are
    # referenced in the issue but not yet modeled; for_visit derives the
    # full list from GETSUM alone.
    DataMapper.define(:reminder_summary) do |m|
      m.rpc "BGOTRG GETSUM"
      m.field 0, :id, :integer
      m.field 1, :name
      m.field 2, :status_code
      m.field 3, :priority, :integer
      m.field 4, :due_date, :fileman_date
    end

    # ========================================================================
    # SCHEDULING (BSDX — Clinical Scheduling for Windows)
    # ========================================================================
    #
    # BSDX RPCs are BMX GLOBAL-ARRAY (recordset) RPCs: over the wire the first
    # response row is a fixed-width column header (e.g. "I00020APPOINTMENTID^
    # T00020ERRORID") and subsequent rows are the caret-delimited data. The
    # mappings below target the single DATA row — the client/gateway is
    # responsible for stripping the header row. RPC
    # names and entry points are taken verbatim from the live #8994 REMOTE
    # PROCEDURE registry dump; parameter shapes from the BSDX07/08/25/31
    # routine entry points in FOIA-RPMS.
    #
    # NOTE: these are exercised via MockClient because no live-dispatch proof
    # exists for this RPC set yet (rpms-rpc#224) — NOT because the backend is
    # blocked. rpms-ops#366 (the YDB releases lacking the #8994 registry) closed
    # 2026-08-23: ^XWB is force-included in the export and its absence fails the
    # build.

    # BSDX ADD NEW APPOINTMENT — APPADD^BSDX07 → $$MAKE^BSDAPI (updates ^SC +
    # ^BSDXAPPT / 9002018.4). Recordset data row: APPOINTMENTID^ERRORID.
    # Success => APPOINTMENTID > 0 and ERRORID empty; failure => "0^<message>".
    # Params (order per APPADD): START^END^DFN^RESOURCE_NAME^LENGTH_MINUTES^
    #   NOTE^ACCESS_TYPE_ID (numeric IEN or literal "WALKIN")^CHART_REQUEST_FLAG.
    DataMapper.define(:scheduling_add_appointment) do |m|
      m.rpc "BSDX ADD NEW APPOINTMENT"
      m.field 0, :appointment_id, :integer
      m.field 1, :error
    end

    # BSDX CANCEL APPOINTMENT — APPDEL^BSDX08 → $$CANCEL^BSDAPI. Recordset data
    # row is the single ERRORID column: empty => success, "<message>" => error.
    # Params: BSDX_APPOINTMENT_IEN^TYPE ("C" clinic-cancelled | "PC" patient-
    #   cancelled)^CANCELLATION_REASON_IEN (409.2)^USER_NOTE.
    DataMapper.define(:scheduling_cancel_appointment) do |m|
      m.rpc "BSDX CANCEL APPOINTMENT"
      m.field 0, :error
    end

    # BSDX UNCANCEL APPT — APPUDEL^BSDX08 (undo a clinic cancellation; patient-
    # cancelled appts cannot be uncancelled). Recordset ERRORID column: empty
    # => success. Params: BSDX_APPOINTMENT_IEN.
    DataMapper.define(:scheduling_uncancel_appointment) do |m|
      m.rpc "BSDX UNCANCEL APPT"
      m.field 0, :error
    end

    # BSDX CHECKIN APPOINTMENT — CHECKIN^BSDX25 (check-in via BSDAPI / ^DGPM
    # check-in node). Recordset header ERRORID^MESSAGE (BSDX25.m:37); the
    # success row is "0^"_MESSAGE (BSDX25.m:74), failures are ERR^BSDX25 text.
    # Params: BSDX_APPOINTMENT_IEN^CHECKIN_DATETIME^CLINIC_CODE^PROVIDER^
    #   ROUTING_SLIP^VISIT_CLASS^VISIT_FORM^OTHER. All 8 must be SENT (empty
    #   ok): BSDXVCL/BSDXVFM/BSDXOG reach APCHK by value with no $G
    #   (BSDX25.m:63) — omitting them <UNDEF>s when the resource links a
    #   hospital location.
    DataMapper.define(:scheduling_checkin_appointment) do |m|
      m.rpc "BSDX CHECKIN APPOINTMENT"
      m.field 0, :error
    end

    # BSDX NOSHOW — NOSHOW^BSDX31 → $$CANCEL^BSDAPI (sets no-show on ^DPT).
    # Recordset data row: ERRORID^ERRORTEXT. IMPORTANT: the ERRORID column here
    # is a SUCCESS flag with INVERTED polarity vs BSDX ADD — the routine writes
    # "1^" on success and "0^<message>" via its error path. So field 0 == 1
    # means OK; field 0 == 0 with ERRORTEXT means failure.
    # Params: BSDX_APPOINTMENT_IEN^NOSHOW_FLAG (1 = no-show, 0 = clear no-show).
    DataMapper.define(:scheduling_noshow_appointment) do |m|
      m.rpc "BSDX NOSHOW"
      m.field 0, :result, :integer
      m.field 1, :error
    end

    # BSDX SEARCH AVAILABILITY — SEARCH^BSDX24. Availability blocks between two
    # dates for one or more resources. Header (BSDX24.m:99):
    #   T RESOURCENAME ^ D DATE ^ T ACCESSTYPE ^ T COMMENT
    # Despite the D-typed header, the DATE column is EXTERNAL format
    # ("SEP 04, 2026"): the routine runs the internal date through DD^%DT
    # before writing the row (BSDX24.m:116-117). The row ends after ACCESSTYPE
    # with a bare trailing "^" — COMMENT is declared but never populated
    # (TODO at BSDX24.m:123; row write at BSDX24.m:124), so :comment is
    # always nil.
    # Params: RESOURCE_NAMES (pipe-delimited "RES1|RES2")^START^END^
    #   ACCESS_TYPES^AMPM^WEEKDAYS.
    DataMapper.define(:scheduling_availability) do |m|
      m.rpc "BSDX SEARCH AVAILABILITY"
      m.field 0, :resource_name
      m.field 1, :date, :external_date
      m.field 2, :access_type
      m.field 3, :comment
    end

    # BSDX ALL APPOINTMENTS — APBLKALL^BSDX05. All appointments across resources
    # in a date range. Header (BSDX05.m:65): D START_TIME ^ D END_TIME ^
    #   I PAT_ID ^ T RES_NAME.
    # Despite the D-typed header, START_TIME/END_TIME are EXTERNAL datetimes
    # ("SEP 04, 2026 09:00"): STCOMM^BSDX05 runs X ^DD("DD") and translates
    # the "@" to a space (BSDX05.m:100-101). RES_NAME is appended per row by
    # GATHER^BSDX05 (BSDX05.m:76). Params: START_DATE^END_DATE.
    DataMapper.define(:scheduling_all_appointments) do |m|
      m.rpc "BSDX ALL APPOINTMENTS"
      m.field 0, :start_time, :external_datetime
      m.field 1, :end_time,   :external_datetime
      m.field 2, :patient_dfn, :integer
      m.field 3, :resource_name
    end

    # BSDX HOSPITAL LOCATION — HOSPLOC^BSDX32. Active clinics from ^SC (file 44).
    # Header (authoritative): I HOSPITAL_LOCATION_ID ^ T HOSPITAL_LOCATION ^
    #   T DEFAULT_PROVIDER ^ T STOP_CODE_NUMBER ^ D INACTIVATE_DATE ^
    #   D REACTIVATE_DATE. Params: (none).
    # Both dates come from $$GET1^DIQ with no "I" flag (BSDX32.m:35-36), so
    # they are EXTERNAL ("JAN 15, 2025"), not FileMan internal (#221). The
    # stop code is GET1^DIQ external too (BSDX32.m:40): the 40.7 NAME
    # ("FAMILY PRACTICE"), not the number.
    DataMapper.define(:scheduling_hospital_location) do |m|
      m.rpc "BSDX HOSPITAL LOCATION"
      m.field 0, :location_ien, :integer
      m.field 1, :location
      m.field 2, :default_provider
      m.field 3, :stop_code
      m.field 4, :inactivate_date, :external_date
      m.field 5, :reactivate_date, :external_date
    end

    # BSDX CLINIC SETUP — CLNSET^BSDX32. Per-clinic scheduling parameters.
    # Header (authoritative): I HOSPITAL_LOCATION_ID ^ T HOSPITAL_LOCATION ^
    #   T CREATE_VISIT ^ T VISIT_SERVICE_CATEGORY ^ T MULTIPLE_CLINIC_CODES_USED?
    #   ^ T VISIT_PROVIDER_REQUIRED ^ T GENERATE_PCCPLUS_FORMS? ^ T MAX_OVERBOOKS.
    # Params: (none).
    DataMapper.define(:scheduling_clinic_setup) do |m|
      m.rpc "BSDX CLINIC SETUP"
      m.field 0, :location_ien, :integer
      m.field 1, :location
      m.field 2, :create_visit
      m.field 3, :visit_service_category
      m.field 4, :multiple_clinic_codes
      m.field 5, :visit_provider_required
      m.field 6, :generate_pccplus_forms
      m.field 7, :max_overbooks, :integer
    end

    # ========================================================================
    # AG PACKAGE REGISTRATION (AGG*, context option AGGRPC)
    # ========================================================================
    #
    # The AG GUI-generation registration write suite. Capture-verified live
    # on bcer-9.0-ydb (rpms-rpc#214); response parsing is custom (a GLOBAL
    # ARRAY of typed records, not caret-per-field), so these mappings carry
    # only the RPC name — RpmsRpc::Agg does the encode/parse and
    # CiaClient#call_rpc_global_array reads the reply to its $C(31) sentinel.
    # The text_blob attribute lets MockClient.seed the raw reply verbatim.
    # Names/registration confirmed in the observed #8994 registry
    # (rpms-ops/data/observed/broker_8994.txt, per #203/#209).

    # AGG ADD NEW PATIENT — ADD^AGGPTADD (return type GLOBAL ARRAY). Params:
    # window name, DFN ("" = new), $C(28)-delimited NAME=VALUE PARMS. Reply
    # header "I00010RESULT^T00080MESSAGE^I00010DFN"; "1^^DFN" ok / "-1^msg"
    # rejected. Parsed by Agg.
    DataMapper.define(:agg_add_patient) do |m|
      m.rpc "AGG ADD NEW PATIENT"
      m.text_blob :reply
    end

    # AGG UPDATE PATIENT — UPD^AGGPTUPD. Same PARMS convention; DFN required.
    # Reply header "I00010RESULT^T01024ERROR^T01024OTHER_PARMS"; "1^^" ok.
    # Parsed by Agg.
    DataMapper.define(:agg_update_patient) do |m|
      m.rpc "AGG UPDATE PATIENT"
      m.text_blob :reply
    end

    # AGG PATIENT EDIT CHECK — CHK^AGGEDCHK. Params: DFN. Reply is the
    # MANDATORY/WARNING completeness battery, header "I00010HIDE_ERROR_NUM^
    # T00030MSG^T00001TYPE^T00030HIDE_WINDOW^T00008HIDE_FIELD^T00050HIDE_TAB^
    # T00001HIDE_KEY". Parsed by Agg.
    DataMapper.define(:agg_patient_edit_check) do |m|
      m.rpc "AGG PATIENT EDIT CHECK"
      m.text_blob :reply
    end

    # CIANBRPC CANRUN — CANRUN^CIANBRPC broker gate. Params: P1 = RPC NAME
    # (the wrapper resolves the file-8994 IEN itself via
    # $$FIND1^DIC(8994,,"QX",RPC) before calling $$CANRUN^CIANBACT with the
    # IEN — CIANBRPC.m:173-175; an IEN argument here would NOT resolve, #225).
    # Scalar "1"/"0": is the RPC in the current context option's RPC
    # multiple. Used by Agg.available? as real registry evidence (#209)
    # without executing the write RPC.
    DataMapper.define(:agg_canrun) do |m|
      m.rpc "CIANBRPC CANRUN"
      m.scalar :can_run
    end
    # ========================================================================
    # BEHAVIORAL HEALTH (AMHG) — rpms-rpc#227
    # ========================================================================

    # AMHG GET VISITS — VISITL^AMHGD (AMHGD.m:10). Visit list for the record
    # selector. One pipe-delimited param, "begin|end|DFN", FileMan dates
    # (#198). Rows arrive NEWEST FIRST: the loop walks ^AMHREC("AE") over
    # INVERSE dates (AMHGD.m:23-26).
    #
    # The header at AMHGD.m:17-18 declares EIGHTEEN columns, the last being
    # T00030DOBI. The row built at AMHGD.m:55 emits SEVENTEEN — AMHDOBI is
    # computed at AMHGD.m:53 and never appended. Do not add an 18th field:
    # the wire has no value for it.
    #
    # Rows are screened per-user by $$ALLOWVI^AMHUTIL(DUZ,AMHIEN)
    # (AMHGD.m:33), so an absent visit is not evidence the visit does not
    # exist — it may be screened from this DUZ.
    DataMapper.define(:amhg_visit_list) do |m|
      m.rpc "AMHG GET VISITS"
      m.field 0,  :ien
      m.field 1,  :visit_date       # internal FileMan date (AMHDT)
      m.field 2,  :display_date     # $$LVDT^AMHGU of the same
      m.field 3,  :pov
      m.field 4,  :axis_v
      m.field 5,  :clinic
      m.field 6,  :activity
      m.field 7,  :visit_type
      m.field 8,  :contact_type
      m.field 9,  :provider
      m.field 10, :signed_marker    # "*" means NOT signed — AMHGD.m:47
      m.field 11, :ehr_flag
      m.field 12, :delete_intakes
      m.field 13, :location
      m.field 14, :group_flag
      m.field 15, :program
      m.field 16, :activity_time
    end

    # AMHG GET VISIT INFORMATION — VI^AMHGDVF (AMHGDVF.m:9). One param: the
    # visit IEN. Twelve fields, header at AMHGDVF.m:16, row at AMHGDVF.m:52.
    #
    # Five columns carry an "IEN~external" pair (R="~", AMHGDVF.m:12):
    # primary_provider, clinic, type_of_contact, encounter_location,
    # community_of_service. Program and appointment_with are external-only —
    # their internal variants are computed at AMHGDVF.m:27 and :45 and then
    # the external value is emitted instead. Splitting is BehavioralHealth's
    # job, not the mapper's.
    #
    # arrival_time is permanently blank: AMHGDVF.m:40 assigns AMHARR="" with
    # the real computation commented out on the same line.
    DataMapper.define(:amhg_visit_information) do |m|
      m.rpc "AMHG GET VISIT INFORMATION"
      m.field 0,  :ien
      m.field 1,  :primary_provider_raw
      m.field 2,  :program
      m.field 3,  :clinic_raw
      m.field 4,  :type_of_contact_raw
      m.field 5,  :arrival_time      # always "" — AMHGDVF.m:40
      m.field 6,  :encounter_date
      m.field 7,  :encounter_location_raw
      m.field 8,  :appointment_with
      m.field 9,  :community_of_service_raw
      m.field 10, :visit
      m.field 11, :ehr_flag
    end
    # -- Visit detail tabs (AMHGDVF unless noted) -----------------------------
    # All take one param: the visit IEN. All emit a typed header + $C(30)-
    # separated rows + a bare $C(31). Single-column responses carry FREE TEXT
    # and are read as raw lines by BehavioralHealth, not caret-split — see the
    # per-mapping notes.

    # ACT^AMHGDVF (AMHGDVF.m:291). Single row. activity_type and
    # local_service_site are "IEN~external" pairs (R="~", AMHGDVF.m:294).
    # interpreter_utilized is blanked when falsy (AMHGDVF.m:311).
    DataMapper.define(:amhg_visit_activity) do |m|
      m.rpc "AMHG GET VISIT ACTIVITY"
      m.field 0, :ien
      m.field 1, :activity_type_raw
      m.field 2, :activity_time
      m.field 3, :flag
      m.field 4, :local_service_site_raw
      m.field 5, :number_served
      m.field 6, :interpreter_utilized
    end

    # AXIS2^AMHGDVF (AMHGDVF.m:55) — despite the name this is the POV
    # (diagnosis) list. Multi-row over ^AMHRPRO("AD",visit).
    #
    # The column named BMXIEN is NOT the record IEN. It is field .01's
    # INTERNAL value (AMHGDVF.m:67) — a pointer to the POV code file. The
    # subfile IEN (AMHPOVI) is never emitted, so these rows cannot be used to
    # address a specific POV entry for update or delete.
    DataMapper.define(:amhg_visit_axis_ii) do |m|
      m.rpc "AMHG GET VISIT AXIS II"
      m.field 0, :code_pointer
      m.field 1, :code
      m.field 2, :narrative
    end

    # AXIS3^AMHGDVF (AMHGDVF.m:76). Single free-text column, multi-row over
    # ^AMHREC(visit,53). Carets are translated to SPACES before transmission
    # ($TR(...,U," "), AMHGDVF.m:88), so the text is caret-safe but any caret
    # the clinician typed is already lost upstream.
    DataMapper.define(:amhg_visit_axis_iii) do |m|
      m.rpc "AMHG GET VISIT AXIS III"
      m.field 0, :text
    end

    # AXIS4^AMHGDVF (AMHGDVF.m:95) — psychosocial stressors, multi-row over
    # ^AMHREC(visit,61). Same BMXIEN caveat as AXIS II: the first column is a
    # pointer into 9002012.9 (AMHGDVF.m:107), not the subfile IEN.
    DataMapper.define(:amhg_visit_axis_iv) do |m|
      m.rpc "AMHG GET VISIT AXIS IV"
      m.field 0, :code_pointer
      m.field 1, :code
      m.field 2, :narrative
    end

    # AXIS5^AMHGDVF (AMHGDVF.m:115). Always exactly one row, even when both
    # values are empty — there is no loop (AMHGDVF.m:123-125).
    DataMapper.define(:amhg_visit_axis_v) do |m|
      m.rpc "AMHG GET VISIT AXIS V"
      m.field 0, :axis_v
      m.field 1, :gaf
    end

    # CC^AMHGDVF (AMHGDVF.m:131). Always exactly one row. The value is the
    # RAW node ^AMHREC(visit,21) with NO caret sanitisation (AMHGDVF.m:140),
    # so a chief complaint containing "^" would split into phantom columns if
    # caret-parsed. Read as a whole line.
    DataMapper.define(:amhg_visit_chief_complaint) do |m|
      m.rpc "AMHG GET VISIT CC"
      m.field 0, :text
    end

    # COMAPP^AMHGDVF (AMHGDVF.m:166). Multi-row over ^AMHREC(visit,81), raw
    # nodes, no caret sanitisation. Read as whole lines.
    DataMapper.define(:amhg_visit_comment_appointment) do |m|
      m.rpc "AMHG GET VISIT COMM APP"
      m.field 0, :text
    end

    # SOAP^AMHGDVF (AMHGDVF.m:146). TWO SOURCES, ONE SHAPE: when piece 10 of
    # ^AMHREC(visit,11) is set the routine delegates to TIU^AMHGDVF2 and
    # returns early (AMHGDVF.m:153-154). Both paths emit the same
    # "T00250Soap" header and $C(30)-separated free-text rows, so callers see
    # one contract — but the text originates from TIU rather than
    # ^AMHREC(visit,31). Raw nodes, no caret sanitisation.
    DataMapper.define(:amhg_visit_soap) do |m|
      m.rpc "AMHG GET VISIT SOAP"
      m.field 0, :text
    end

    # ASSESS^AMHGDINT (AMHGDINT.m:103). Multi-row free text.
    #
    # The parameter is an INTAKE IEN, not a visit IEN, despite the RPC name:
    # the loop walks ^AMHRINTK(ien,41) (AMHGDINT.m:114). A visit IEN yields an
    # empty result rather than an error, because the read is guarded by
    # I $G(AMHIEN) (AMHGDINT.m:113).
    DataMapper.define(:amhg_visit_assessment) do |m|
      m.rpc "AMHG GET VISIT ASSESSMENT"
      m.field 0, :text
    end

    # SCREENN^AMHGDVF3 (AMHGDVF3.m:103).
    #
    # UPSTREAM DEFECT — at most ONE screening is ever returned. AMHI is
    # incremented once at AMHGDVF3.m:157, BEFORE the F I= loop at :161; every
    # matching screening then writes @RETVAL@(AMHI) with no further increment
    # (:162 onward), so each overwrites the last. The survivor is whichever
    # screening is LAST in the fixed list order and has a non-empty result:
    # Alcohol, Depression, IPV/DV, Suicide Risk, Suicide Screening, Unhealthy
    # Drug, SDOH Food, SDOH Housing, SDOH Transportation, SDOH Utilities,
    # SDOH Interpersonal.
    #
    # A visit carrying both a Depression and a Suicide Risk screen therefore
    # reports only Suicide Risk. Do not present this as a complete screening
    # list.
    #
    # The BMXIEN column is the VISIT IEN repeated, not a per-screening id.
    DataMapper.define(:amhg_visit_screening) do |m|
      m.rpc "AMHG GET VISIT SCREENING"
      m.field 0, :visit_ien
      m.field 1, :screening_type
      m.field 2, :result
      m.field 3, :provider_ien
      m.field 4, :provider
      m.field 5, :comment
    end
    # -- Treatment plans -------------------------------------------------------

    # TPL^AMHGD (AMHGD.m:156). One param "begin|end|DFN". Screened per-user by
    # $$ALLOWTP^AMHLETP (AMHGD.m:174), so an empty list means "none visible to
    # this DUZ".
    #
    # BOUNDARY WARNING: the inverse-date adjustments are the REVERSE of
    # VISITL^AMHGD — .0001/.9999 here (AMHGD.m:167-168) against .9999/.0001
    # there (AMHGD.m:23-24). The two RPCs include their range edges
    # differently, so one date range does not select equivalently across both.
    #
    # :problem falls back to the diagnosis node ^AMHPTXP(ien,21,1,0) when
    # field 1101 is empty (AMHGD.m:178), so the column mixes problem text and
    # diagnosis text.
    #
    # Dates here are $$LVDT-formatted for display; TP^AMHGDTP returns the same
    # fields as raw internal FileMan dates.
    DataMapper.define(:amhg_treatment_plan_list) do |m|
      m.rpc "AMHG GET TREATMENT PLANS"
      m.field 0, :ien
      m.field 1, :sort_date          # internal FileMan
      m.field 2, :date_established   # $$LVDT display
      m.field 3, :program
      m.field 4, :status
      m.field 5, :problem
      m.field 6, :provider
      m.field 7, :review_date        # $$LVDT display
      m.field 8, :review_count
      m.field 9, :closed_date        # $$LVDT display
    end

    # TP^AMHGDTP (AMHGDTP.m:11). One param: the plan IEN.
    #
    # Dates are INTERNAL FileMan here, unlike the list above.
    #
    # AMHGDTP.m:29 builds AMHPRGS as an IEN~name pair and :44 emits the plain
    # external AMHPRG instead, so program carries no IEN. designated_provider
    # (:32) and concur_supervisor (:37) are genuine pairs.
    DataMapper.define(:amhg_treatment_plan) do |m|
      m.rpc "AMHG GET TREATMENT PLAN"
      m.field 0,  :ien
      m.field 1,  :date_established
      m.field 2,  :program            # external only — AMHGDTP.m:44
      m.field 3,  :target_date
      m.field 4,  :review_date
      m.field 5,  :date_closed
      m.field 6,  :designated_provider_raw
      m.field 7,  :problem_list
      m.field 8,  :case_admit
      m.field 9,  :concurred_date
      m.field 10, :concur_supervisor_raw
      m.field 11, :dsm4
    end

    # REV^AMHGDTP (AMHGDTP.m:175). Multi-row over ^AMHPTXP(plan,41).
    #
    # BMXIEN is the PLAN ien repeated; BMXIEN2 is the review subfile IEN
    # (AMHDA) — the only addressable identifier on the row (AMHGDTP.m:197).
    #
    # The columns named ReviewProviderComplete / ReviewSupervisorComplete do
    # NOT carry completion status: AMHGDTP.m:193-194 build them as IEN~name
    # pairs. The plain ReviewProvider / ReviewSupervisor columns are the
    # external names only. Reading the *Complete columns as booleans would
    # mark every named reviewer complete.
    DataMapper.define(:amhg_treatment_plan_reviews) do |m|
      m.rpc "AMHG GET TP REVIEW"
      m.field 0, :plan_ien
      m.field 1, :ien                    # BMXIEN2 — the review subfile IEN
      m.field 2, :review_date            # $$LVDT display
      m.field 3, :review_provider_name
      m.field 4, :review_supervisor_name
      m.field 5, :next_review_date       # $$LVDT display
      m.field 6, :review_provider_raw    # IEN~name despite "Complete"
      m.field 7, :review_supervisor_raw  # IEN~name despite "Complete"
    end

    # PPAR^AMHGDTP (AMHGDTP.m:201). Multi-row over ^AMHPTXP(plan,17). BMXIEN
    # is the PLAN ien repeated and AMHDA is never emitted (AMHGDTP.m:215), so
    # a participant row cannot be addressed for edit or delete.
    DataMapper.define(:amhg_treatment_plan_participants) do |m|
      m.rpc "AMHG GET TP PLAN PARTICIPANTS"
      m.field 0, :plan_ien
      m.field 1, :participant
      m.field 2, :relationship
    end

    # NARR^AMHGDTP (AMHGDTP.m:156). Single free-text column, multi-row over
    # ^AMHPTXP(plan,18), raw nodes with no caret sanitisation (:168).
    DataMapper.define(:amhg_treatment_plan_narrative) do |m|
      m.rpc "AMHG GET TP NARRATIVE"
      m.field 0, :text
    end
    # -- Suicide risk forms ----------------------------------------------------

    # SFL^AMHGD (AMHGD.m:235). One param "begin|end|DFN". Screened per-user by
    # $$ALLOW^AMHSFR (AMHGD.m:252) — an empty list means "none visible to this
    # DUZ". Inverse-date adjustments are .0001/.9999 (AMHGD.m:246-247), the
    # same variant as the treatment-plan list and the OPPOSITE of VISITL.
    #
    # :incomplete_marker is "I" when the form is INCOMPLETE and empty when it
    # is complete (AMHGD.m:256) — a presence flag, not a boolean.
    DataMapper.define(:amhg_suicide_form_list) do |m|
      m.rpc "AMHG GET SUICIDE FORMS"
      m.field 0, :ien
      m.field 1, :sort_date          # internal FileMan
      m.field 2, :date               # $$LVDT display
      m.field 3, :local_case_number
      m.field 4, :provider
      m.field 5, :suicidal_behavior
      m.field 6, :incomplete_marker
    end

    # SF^AMHGDSF (AMHGDSF.m:11). One param: the form IEN. Single row.
    #
    # SIXTEEN columns. The header is built across TWO SET statements
    # (AMHGDSF.m:19-20), so any reader that stops at the first sees only
    # eleven and silently drops Lethality through DispositionText.
    #
    # provider, community_where_occurred and disposition are IEN~name pairs
    # (AMHGDSF.m:22, :27, :43). date_of_act is internal FileMan (:24).
    DataMapper.define(:amhg_suicide_form) do |m|
      m.rpc "AMHG GET SUICIDE FORM"
      m.field 0,  :ien
      m.field 1,  :local_case_number
      m.field 2,  :provider_raw
      m.field 3,  :date_of_act
      m.field 4,  :community_where_occurred_raw
      m.field 5,  :relationship_status
      m.field 6,  :employment_status
      m.field 7,  :education
      m.field 8,  :highest_grade
      m.field 9,  :suicidal_behavior
      m.field 10, :previous_attempts
      m.field 11, :lethality
      m.field 12, :location_of_act
      m.field 13, :location_other
      m.field 14, :disposition_raw
      m.field 15, :disposition_text
    end

    # METH^AMHGDSF (AMHGDSF.m:48). Multi-row over ^AMHPSUIC(form,11).
    #
    # ROW COUNT IS NOT METHOD COUNT. Method 7 with recorded drugs emits ONE
    # ROW PER DRUG (AMHGDSF.m:73), so a single method repeats across rows.
    # Any other method emits exactly one row with the drug columns blank
    # (:75-78). BMXIEN is the FORM ien repeated; the method subfile IEN
    # (AMHDA) is never emitted, so rows cannot be grouped or addressed.
    DataMapper.define(:amhg_suicide_form_methods) do |m|
      m.rpc "AMHG GET SUICIDE FORM METHOD"
      m.field 0, :form_ien
      m.field 1, :method
      m.field 2, :method_if_other
      m.field 3, :drug_raw          # IEN~name when present
      m.field 4, :drug_if_other
    end

    # SUB^AMHGDSF (AMHGDSF.m:82). Always emits at least one row: when field
    # .26 is not "2" the routine still writes a row carrying the substance
    # value with blank drug columns (AMHGDSF.m:106-108). An empty result
    # therefore never means "not asked".
    DataMapper.define(:amhg_suicide_form_substances) do |m|
      m.rpc "AMHG GET SUICIDE FORM SUB"
      m.field 0, :form_ien
      m.field 1, :substance
      m.field 2, :drug_raw          # IEN~name when present
      m.field 3, :drug_if_other
    end

    # CF^AMHGDSF (AMHGDSF.m:112). Plain multi-row list over
    # ^AMHPSUIC(form,13). BMXIEN is the form IEN repeated.
    DataMapper.define(:amhg_suicide_form_contributing_factors) do |m|
      m.rpc "AMHG GET SUICIDE FORM CF"
      m.field 0, :form_ien
      m.field 1, :contributing_factor
      m.field 2, :if_other
    end

    # ========================================================================
    # PATIENT REGISTRATION GUI (AGG*)
    # ========================================================================

    # AGG LOOKUP PATIENTS — FND^AGGPTLKP. The IHS division-aware patient
    # lookup: unlike stock ORWPT LIST ALL it screens on the calling user's
    # division via ^AUPNPAT(DFN,41,DUZ(2)) and knows about inactive patients.
    #
    # Caller parameters (AGGPTLKP.m:7, FND(DATA,TEXT,TYPE,ALL,INAC)):
    #   1 TEXT - search text          2 TYPE - search type code, "" = all xrefs
    #   3 ALL  - "1" = all divisions  4 INAC - "1" = include inactive
    # There is no result-limit parameter; see RpmsRpc::Patient.lookup.
    #
    # Typed header (AGGPTLKP.m:174), rows per AGGPTLKP.m:208:
    #   DFN^PATIENT_NAME^HRN^SSN^DOB^DOD^SENS_FLAG^ALIAS^INACTIVE
    # COMM and MOMDN are appended only when the facility's community-display
    # flag is "Y" AND ALL=1 (AGGPTLKP.m:175).
    #
    # :dfn_raw is deliberately a string — an M error can arrive as a data row,
    # and :integer coercion would turn "M ERROR" into a plausible-looking 0.
    DataMapper.define(:patient_lookup_agg) do |m|
      m.rpc "AGG LOOKUP PATIENTS"
      m.field 0,  :dfn_raw
      m.field 1,  :name
      m.field 2,  :hrn
      m.field 3,  :ssn_raw
      m.field 4,  :dob
      m.field 5,  :dod
      m.field 6,  :sens_flag
      m.field 7,  :alias
      m.field 8,  :inactive_raw
      m.field 9,  :community
      m.field 10, :mothers_maiden_name
    end
  end
end
