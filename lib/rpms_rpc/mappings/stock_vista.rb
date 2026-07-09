# frozen_string_literal: true

require_relative "../data_mapper"

# Stock-VistA RPC response mappings (kernel + clinical namespaces that
# exist on any VistA: ORW*/ORQQ*/TIU/XUS/XU/XM/XQAL/PSO/GMTS/...).
# Bucketed here ahead of the vista-rpc extraction; registers into the
# same DataMapper registry as mappings/ihs.rb. Loaded via
# `require "rpms_rpc/mappings"` — see ../mappings.rb.
module RpmsRpc
  module Mappings
    # ========================================================================
    # PATIENT (ORWPT*, BHDPTRPC*)
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

    # ORWPT ID INFO — patient identifier projection. Live shape against
    # staging (DFN=3 / MOUSE,MICKEY M):
    #   "000009999^2100214^M^N^^7819^^MOUSE,MICKEY M"
    #     [0] ssn       [1] dob (fileman) [2] sex      [3] race_code
    #     [4] reserved  [5] site_ien      [6] reserved [7] name
    # Despite the "ID INFO" name, this RPC does NOT return address,
    # city, state, zip, phone, tribal enrollment, service area, or
    # coverage — those fields were hallucinated in the prior mapping.
    # IHS demographic detail lives in the BHDPTRPC family of RPCs (not
    # installed on staging — see rr-6jr).
    DataMapper.define(:patient_id_info) do |m|
      m.rpc "ORWPT ID INFO"
      m.field 0, :ssn
      m.field 1, :dob, :fileman_date
      m.field 2, :sex
      m.field 3, :race_code
      m.field 5, :site_ien, :integer
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
    # Format: ALLERGEN^REACTION^SEVERITY
    DataMapper.define(:allergy_list) do |m|
      m.rpc "ORQQAL LIST"
      m.field 0, :allergen
      m.field 1, :reaction
      m.field 2, :severity
    end

    # ORQQPL LIST — patient problem list (multi-line)
    # Format: IEN^STATUS^DESCRIPTION^ICD_CODE^ONSET_DATE^RECORDED_DATE^PROVIDER_DUZ
    DataMapper.define(:problem_list) do |m|
      m.rpc "ORQQPL LIST"
      m.field 0, :ien
      m.field 1, :status
      m.field 2, :description
      m.field 3, :icd_code, :string, terminology: :icd10
      m.field 4, :onset_date,    :fileman_date
      m.field 5, :recorded_date, :fileman_date
      m.field 6, :provider_duz, :string, pointer: { file: 200 }
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

    # ORQQVI VITALS — patient vitals (multi-line)
    # Format: TYPE^VALUE^UNITS^DATE
    DataMapper.define(:vitals) do |m|
      m.rpc "ORQQVI VITALS"
      m.field 0, :type
      m.field 1, :value
      m.field 2, :units
      m.field 3, :recorded_date, :fileman_date
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
    # CLINICAL DATA (ORQQPS*, ORQQCP*, ORQQCT*, ORQQGO*, ORWPCE*)
    # ========================================================================

    # ORQQPS LIST — medication list (multi-line)
    # Format: IEN^DRUG_NAME^SIG^STATUS^LAST_FILL^REFILLS^PROVIDER
    DataMapper.define(:medication_list) do |m|
      m.rpc "ORQQPS LIST"
      m.field 0, :ien
      m.field 1, :drug_name, :string, terminology: :rxnorm, pointer: { file: 50 }
      m.field 2, :sig
      m.field 3, :status
      m.field 4, :last_fill,   :fileman_date
      m.field 5, :refills,     :integer
      m.field 6, :provider, :string, pointer: { file: 200 }
    end

    # ORQQCP LIST — care plan list (multi-line)
    # Format: IEN^TITLE^STATUS^INTENT^CATEGORY^START_DATE^END_DATE^
    #         AUTHOR_DUZ^AUTHOR_NAME^GOAL_IENS^ACTIVITY^DESCRIPTION^NOTE
    DataMapper.define(:care_plan_list) do |m|
      m.rpc "ORQQCP LIST"
      m.field 0,  :ien
      m.field 1,  :title
      m.field 2,  :status
      m.field 3,  :intent
      m.field 4,  :category
      m.field 5,  :start_date, :fileman_date
      m.field 6,  :end_date,   :fileman_date
      m.field 7,  :author_duz
      m.field 8,  :author_name
      m.field 9,  :goal_iens
      m.field 10, :activity
      m.field 11, :description
      m.field 12, :note
    end

    # ORQQCT LIST — care team list (multi-line)
    # Format: IEN^TEAM_NAME^STATUS^CATEGORY^START_DATE^END_DATE^
    #         PARTICIPANTS^REASON_CODE^REASON_DISPLAY^ORGANIZATION
    # The PARTICIPANTS field is a sub-encoded string parsed by the API module:
    #   DUZ~NAME~ROLE~START~END;DUZ~NAME~ROLE~START~END;...
    DataMapper.define(:care_team_list) do |m|
      m.rpc "ORQQCT LIST"
      m.field 0, :ien
      m.field 1, :team_name
      m.field 2, :status
      m.field 3, :category
      m.field 4, :start_date, :fileman_date
      m.field 5, :end_date,   :fileman_date
      m.field 6, :participants_raw
      m.field 7, :reason_code
      m.field 8, :reason_display
      m.field 9, :organization
    end

    # ORQQGO LIST — goal list (multi-line)
    # Format: IEN^GOAL_TEXT^LIFECYCLE_STATUS^ACHIEVEMENT_STATUS^CATEGORY^
    #         PRIORITY^START_DATE^TARGET_DATE^STATUS_DATE^
    #         PROVIDER_DUZ^PROVIDER_NAME^NOTE
    DataMapper.define(:goal_list) do |m|
      m.rpc "ORQQGO LIST"
      m.field 0,  :ien
      m.field 1,  :goal_text
      m.field 2,  :lifecycle_status
      m.field 3,  :achievement_status
      m.field 4,  :category
      m.field 5,  :priority
      m.field 6,  :start_date,  :fileman_date
      m.field 7,  :target_date, :fileman_date
      m.field 8,  :status_date, :fileman_date
      m.field 9,  :provider_duz
      m.field 10, :provider_name
      m.field 11, :note
    end

    # ORWPCE PROCEDURE LIST — procedure list (multi-line)
    # Format: IEN^NAME^DATE^PROVIDER^STATUS
    DataMapper.define(:procedure_list) do |m|
      m.rpc "ORWPCE PROCEDURE LIST"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :date,     :fileman_date
      m.field 3, :provider
      m.field 4, :status
    end

    # ORWPCE IMPLANT LIST — implanted device list (multi-line)
    # Format: IEN^UDI^DEVICE_ID^STATUS^DEVICE_NAME^MANUFACTURER^MODEL^SERIAL^LOT^MFG_DATE^EXP_DATE^TYPE_CODE^TYPE_DISPLAY^DISTINCT_ID
    DataMapper.define(:device_list) do |m|
      m.rpc "ORWPCE IMPLANT LIST"
      m.field 0, :ien
      m.field 1, :udi
      m.field 2, :device_identifier
      m.field 3, :status
      m.field 4, :name
      m.field 5, :manufacturer
      m.field 6, :model_number
      m.field 7, :serial_number
      m.field 8, :lot_number
      m.field 9, :manufacture_date, :fileman_date
      m.field 10, :expiration_date, :fileman_date
      m.field 11, :snomed_code
      m.field 12, :device_type
      m.field 13, :distinct_id
    end

    # ========================================================================
    # LAB & RADIOLOGY (ORWLRR*, ORWRA*)
    # ========================================================================

    # ORWLRR RESULT LIST — lab result list (multi-line).
    # RPC is invoked with a single composite param: "dfn^from_date^to_date".
    # Format: IEN^TEST_NAME^RESULT^UNITS^REF_RANGE^ABNORMAL_FLAG^COLLECTION_DATE^STATUS
    DataMapper.define(:lab_result_list) do |m|
      m.rpc "ORWLRR RESULT LIST"
      m.field 0, :ien,             :integer
      m.field 1, :test_name
      m.field 2, :result
      m.field 3, :units
      m.field 4, :reference_range
      m.field 5, :abnormal_flag
      m.field 6, :collection_date, :fileman_datetime
      m.field 7, :status
    end

    # ORWRA REPORT LIST — radiology report list (multi-line)
    # Format: IEN^EXAM_NAME^CPT_CODE^STATUS^EXAM_DATE^REPORT_DATE^RAD_DUZ^
    #         RAD_NAME^IMPRESSION^IMAGING_STUDY_IEN^REPORT_TEXT
    DataMapper.define(:radiology_list) do |m|
      m.rpc "ORWRA REPORT LIST"
      m.field 0,  :ien,                :integer
      m.field 1,  :exam_name
      m.field 2,  :cpt_code
      m.field 3,  :status
      m.field 4,  :exam_date,          :fileman_datetime
      m.field 5,  :report_date,        :fileman_datetime
      m.field 6,  :radiologist_duz
      m.field 7,  :radiologist_name
      m.field 8,  :impression
      m.field 9,  :imaging_study_ien,  :integer
      m.field 10, :report_text
    end

    # ========================================================================
    # AUTHENTICATION (XUS*)
    # ========================================================================

    # XUS GET USER INFO — authenticated user info. Response is line-based,
    # one value per line — not caret-delimited. Live shape observed against
    # staging:
    #   [0] "1"                              → duz
    #   [1] "PROVIDER,TEST"                  → name (FAMILY,GIVEN)
    #   [2] "Adam Adam"                      → display_name
    #   [3] "7819^DEMO IHS CLINIC^8904"      → current_site (IEN^NAME^ABBR)
    #   [4]..[6] ""                          → reserved
    #   [7] "30"                             → user_class_ien (pointer into
    #                                          USER CLASS file #8932.1 —
    #                                          NOT the auth class code that
    #                                          av_code's :user_class returns)
    DataMapper.define(:user_info) do |m|
      m.rpc "XUS GET USER INFO"
      m.line_field 0, :duz,  :integer
      m.line_field 1, :name
      m.line_field 2, :display_name
      m.line_field 3, :current_site
      m.line_field 7, :user_class_ien, :integer
    end

    # ========================================================================
    # COMMUNICATION (MailMan XM*, XQAL*)
    # ========================================================================

    # XM GET MESSAGE / XM GET MESSAGES — MailMan message.
    # Format: IEN^PATIENT_DFN^SENDER_DUZ^SENDER_NAME^RECIPIENT_DUZ^RECIPIENT_NAME^
    #         SUBJECT^BODY^SENT_AT^READ_AT^STATUS^PRIORITY^CATEGORY^PARENT_ID^THREAD_ID^BASKET
    DataMapper.define(:mailman_message) do |m|
      m.rpc "XM GET MESSAGE"
      m.field 0,  :ien, :integer
      m.field 1,  :patient_dfn, :integer
      m.field 2,  :sender_duz, :integer
      m.field 3,  :sender_name
      m.field 4,  :recipient_duz, :integer
      m.field 5,  :recipient_name
      m.field 6,  :subject
      m.field 7,  :body
      m.field 8,  :sent_at, :fileman_datetime
      m.field 9,  :read_at, :fileman_datetime
      m.field 10, :status
      m.field 11, :priority
      m.field 12, :category
      m.field 13, :parent_id, :integer
      m.field 14, :thread_id
      m.field 15, :basket
    end

    # XM GET MESSAGES — patient-scoped MailMan messages (same wire shape as GET).
    DataMapper.define(:mailman_messages_for_patient) do |m|
      m.rpc "XM GET MESSAGES"
      m.field 0,  :ien, :integer
      m.field 1,  :patient_dfn, :integer
      m.field 2,  :sender_duz, :integer
      m.field 3,  :sender_name
      m.field 4,  :recipient_duz, :integer
      m.field 5,  :recipient_name
      m.field 6,  :subject
      m.field 7,  :body
      m.field 8,  :sent_at, :fileman_datetime
      m.field 9,  :read_at, :fileman_datetime
      m.field 10, :status
      m.field 11, :priority
      m.field 12, :category
      m.field 13, :parent_id, :integer
      m.field 14, :thread_id
      m.field 15, :basket
    end

    # XM SEND MESSAGE — write result: SUCCESS^MESSAGE_IEN^ERROR
    DataMapper.define(:mailman_send) do |m|
      m.rpc "XM SEND MESSAGE"
      m.field 0, :success, :boolean
      m.field 1, :message_ien, :integer
      m.field 2, :error
    end

    # XM REPLY MESSAGE — write result: SUCCESS^MESSAGE_IEN^THREAD_ID^ERROR
    DataMapper.define(:mailman_reply) do |m|
      m.rpc "XM REPLY MESSAGE"
      m.field 0, :success, :boolean
      m.field 1, :message_ien, :integer
      m.field 2, :thread_id
      m.field 3, :error
    end

    # XM GET THREAD — MailMan thread messages (same wire shape as GET).
    DataMapper.define(:mailman_thread) do |m|
      m.rpc "XM GET THREAD"
      m.field 0,  :ien, :integer
      m.field 1,  :patient_dfn, :integer
      m.field 2,  :sender_duz, :integer
      m.field 3,  :sender_name
      m.field 4,  :recipient_duz, :integer
      m.field 5,  :recipient_name
      m.field 6,  :subject
      m.field 7,  :body
      m.field 8,  :sent_at, :fileman_datetime
      m.field 9,  :read_at, :fileman_datetime
      m.field 10, :status
      m.field 11, :priority
      m.field 12, :category
      m.field 13, :parent_id, :integer
      m.field 14, :thread_id
      m.field 15, :basket
    end

    # XM GET INBOX — MailMan inbox messages (same wire shape as GET).
    DataMapper.define(:mailman_inbox) do |m|
      m.rpc "XM GET INBOX"
      m.field 0,  :ien, :integer
      m.field 1,  :patient_dfn, :integer
      m.field 2,  :sender_duz, :integer
      m.field 3,  :sender_name
      m.field 4,  :recipient_duz, :integer
      m.field 5,  :recipient_name
      m.field 6,  :subject
      m.field 7,  :body
      m.field 8,  :sent_at, :fileman_datetime
      m.field 9,  :read_at, :fileman_datetime
      m.field 10, :status
      m.field 11, :priority
      m.field 12, :category
      m.field 13, :parent_id, :integer
      m.field 14, :thread_id
      m.field 15, :basket
    end

    # XQAL NEW ALERTS — pending alert list.
    # Format: ALERT_IEN^USER_DUZ^MESSAGE^CREATED_AT^PRIORITY^CATEGORY^STATUS
    DataMapper.define(:xqal_alert) do |m|
      m.rpc "XQAL NEW ALERTS"
      m.field 0, :alert_ien, :integer
      m.field 1, :user_duz, :integer
      m.field 2, :message
      m.field 3, :created_at, :fileman_datetime
      m.field 4, :priority
      m.field 5, :category
      m.field 6, :status
    end

    # XQAL MARK READ — write result: SUCCESS^ERROR
    DataMapper.define(:xqal_mark_read) do |m|
      m.rpc "XQAL MARK READ"
      m.field 0, :success, :boolean
      m.field 1, :error
    end

    # XQAL FORWARD — write result: SUCCESS^NEW_ALERT_IEN^ERROR
    DataMapper.define(:xqal_forward) do |m|
      m.rpc "XQAL FORWARD"
      m.field 0, :success, :boolean
      m.field 1, :new_alert_ien, :integer
      m.field 2, :error
    end

    # ========================================================================
    # HEALTH SUMMARY & REMINDERS (ORWRP*, GMTS*, ORQQPX*)
    # ========================================================================

    # ORWRP TYPES — report type list (multi-line)
    # Format: IEN^NAME^DESCRIPTION^OWNER
    DataMapper.define(:report_types) do |m|
      m.rpc "ORWRP TYPES"
      m.field 0, :ien, :integer
      m.field 1, :name
      m.field 2, :description
      m.field 3, :owner
    end

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

    # ========================================================================
    # LINE-BASED RESPONSES
    # ========================================================================

    # XUS SIGNON SETUP — signon setup (returns "OK" or error)
    DataMapper.define(:signon_setup) do |m|
      m.rpc "XUS SIGNON SETUP"
      m.scalar :status, :string
    end

    # XUS AV CODE — authentication result (line-based)
    # Line 0: DUZ (or 0 for failure)
    # Line 1: error code
    # Line 2: verify-code-change flag
    # Line 3: message / greeting
    # Line 4: unused
    # Line 5: user class
    DataMapper.define(:av_code) do |m|
      m.rpc "XUS AV CODE"
      m.line_field 0, :duz, :integer
      m.line_field 1, :error_code, :integer
      m.line_field 2, :verify_needs_change, :integer
      m.line_field 3, :message
      m.line_field 5, :user_class, :integer
    end

    # XUS CVC — CVC verification
    DataMapper.define(:cvc_verify) do |m|
      m.rpc "XUS CVC"
      m.line_field 0, :result_code, :integer
    end

    # ORWU USERKEYS — user security keys (multi-line, one key per line)
    DataMapper.define(:user_keys) do |m|
      m.rpc "ORWU USERKEYS"
      m.field 0, :key_name
    end

    # ========================================================================
    # TEXT BLOB RESPONSES (free text reports)
    # ========================================================================

    # ORWRP REPORT TEXT — health summary report text
    DataMapper.define(:report_text) do |m|
      m.rpc "ORWRP REPORT TEXT"
      m.text_blob :report_text
    end

    # ORWRP TYPE COMPONENTS — report type component list
    DataMapper.define(:report_type_components) do |m|
      m.rpc "ORWRP TYPE COMPONENTS"
      m.field 0, :ien, :integer
      m.field 1, :name
      m.field 2, :abbreviation
      m.field 3, :sequence, :integer
    end

    # GMTS PWH REPORT — patient health summary report text
    DataMapper.define(:health_summary_report) do |m|
      m.rpc "GMTS PWH REPORT"
      m.text_blob :report_text
    end

    # GMTS FLOWSHEET LIST — flowsheet definitions (multi-line)
    DataMapper.define(:flowsheet_list) do |m|
      m.rpc "GMTS FLOWSHEET LIST"
      m.field 0, :ien, :integer
      m.field 1, :name
      m.field 2, :description
    end

    # GMTS FLOWSHEET DATA — patient flowsheet table text
    DataMapper.define(:flowsheet_data) do |m|
      m.rpc "GMTS FLOWSHEET DATA"
      m.text_blob :flowsheet_text
    end

    # GMTS MAINT ITEMS — maintenance items (multi-line)
    DataMapper.define(:maint_items) do |m|
      m.rpc "GMTS MAINT ITEMS"
      m.field 0, :ien, :integer
      m.field 1, :name
      m.field 2, :category
      m.field 3, :status
      m.field 4, :last_done, :fileman_date
      m.field 5, :next_due,  :fileman_date
      m.field 6, :frequency
    end

    # ORWLRR REPORT — full lab report text
    DataMapper.define(:lab_report) do |m|
      m.rpc "ORWLRR REPORT"
      m.text_blob :report_text
    end

    # ORWLRR REPORT LIST — DiagnosticReport-style aggregated panels (multi-line)
    # Format: IEN^REPORT_NAME^LOINC_CODE^STATUS^COLLECTION_DATE^RESULT_DATE^
    #         VERIFIER_DUZ^VERIFIER_NAME^RESULT_IENS^INTERPRETATION
    DataMapper.define(:lab_report_list) do |m|
      m.rpc "ORWLRR REPORT LIST"
      m.field 0, :ien,             :integer
      m.field 1, :report_name
      m.field 2, :loinc_code
      m.field 3, :status
      m.field 4, :collection_date, :fileman_datetime
      m.field 5, :result_date,     :fileman_datetime
      m.field 6, :verifier_duz
      m.field 7, :verifier_name
      m.field 8, :result_iens
      m.field 9, :interpretation
    end

    # ORWRA REPORT — full radiology report text
    DataMapper.define(:radiology_report) do |m|
      m.rpc "ORWRA REPORT"
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

    # ORQQCP GET — single care plan.
    # First line: TITLE^STATUS^INTENT^CATEGORY^START_DATE^END_DATE^
    #             AUTHOR_DUZ^AUTHOR_NAME^GOAL_IENS^ACTIVITY^(unused)^PATIENT_DFN
    # Subsequent lines: free-text description (joined by the API module).
    DataMapper.define(:care_plan_detail) do |m|
      m.rpc "ORQQCP GET"
      m.field 0,  :title
      m.field 1,  :status
      m.field 2,  :intent
      m.field 3,  :category
      m.field 4,  :start_date, :fileman_date
      m.field 5,  :end_date,   :fileman_date
      m.field 6,  :author_duz
      m.field 7,  :author_name
      m.field 8,  :goal_iens
      m.field 9,  :activity
      m.field 11, :patient_dfn, :integer
    end

    # ORQQCT GET — single care team. IEN is passed as the RPC param and
    # echoed by the API module via extras (gateway does the same).
    # First line: TEAM_NAME^STATUS^CATEGORY^START_DATE^END_DATE^
    #             PARTICIPANTS^REASON_CODE^REASON_DISPLAY^ORGANIZATION^PATIENT_DFN
    DataMapper.define(:care_team_detail) do |m|
      m.rpc "ORQQCT GET"
      m.field 0, :team_name
      m.field 1, :status
      m.field 2, :category
      m.field 3, :start_date, :fileman_date
      m.field 4, :end_date,   :fileman_date
      m.field 5, :participants_raw
      m.field 6, :reason_code
      m.field 7, :reason_display
      m.field 8, :organization
      m.field 9, :patient_dfn, :integer
    end

    # ORQQGO GET — single goal. IEN is passed as the RPC param and echoed
    # by the API module via extras (gateway does the same).
    # First line: GOAL_TEXT^LIFECYCLE_STATUS^ACHIEVEMENT_STATUS^CATEGORY^
    #             PRIORITY^START_DATE^TARGET_DATE^STATUS_DATE^
    #             PROVIDER_DUZ^PROVIDER_NAME^(unused)^PATIENT_DFN
    # Subsequent lines: free-text note (joined by the API module).
    DataMapper.define(:goal_detail) do |m|
      m.rpc "ORQQGO GET"
      m.field 0,  :goal_text
      m.field 1,  :lifecycle_status
      m.field 2,  :achievement_status
      m.field 3,  :category
      m.field 4,  :priority
      m.field 5,  :start_date,  :fileman_date
      m.field 6,  :target_date, :fileman_date
      m.field 7,  :status_date, :fileman_date
      m.field 8,  :provider_duz
      m.field 9,  :provider_name
      m.field 11, :patient_dfn, :integer
    end

    # ORWPCE PROCEDURE GET — single procedure
    DataMapper.define(:procedure_detail) do |m|
      m.rpc "ORWPCE PROCEDURE GET"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :date,     :fileman_date
      m.field 3, :provider
      m.field 4, :status
      m.field 5, :cpt_code
    end

    # ORWPCE IMPLANT GET — single implanted device
    # Format: UDI^DEVICE_ID^STATUS^DEVICE_NAME^MANUFACTURER^MODEL^SERIAL^LOT^MFG_DATE^EXP_DATE^TYPE_CODE^TYPE_DISPLAY^DISTINCT_ID^PATIENT_DFN
    DataMapper.define(:device_detail) do |m|
      m.rpc "ORWPCE IMPLANT GET"
      m.field 0, :udi
      m.field 1, :device_identifier
      m.field 2, :status
      m.field 3, :name
      m.field 4, :manufacturer
      m.field 5, :model_number
      m.field 6, :serial_number
      m.field 7, :lot_number
      m.field 8, :manufacture_date, :fileman_date
      m.field 9, :expiration_date, :fileman_date
      m.field 10, :snomed_code
      m.field 11, :device_type
      m.field 12, :distinct_id
      m.field 13, :patient_dfn
    end

    # ========================================================================
    # PATIENT RECENT LIST & AGG EDITING (ORWPT*, BEHOENCX*)
    # ========================================================================

    # ORWPT LIST RECENT — recent patients (multi-line)
    # Format: DFN^NAME^LAST_ACCESSED
    DataMapper.define(:patient_recent) do |m|
      m.rpc "ORWPT LIST RECENT"
      m.field 0, :dfn, :integer
      m.field 1, :name
      m.field 2, :last_accessed
    end

    # ORWPT SAVE RECENT — write-only (success/failure)
    DataMapper.define(:patient_save_recent) do |m|
      m.rpc "ORWPT SAVE RECENT"
      m.scalar :success, :boolean
    end

    # ========================================================================
    # SECURITY KEY MANAGEMENT (XU KEY*)
    # ========================================================================

    # XU KEY LIST — key list (multi-line)
    # Format per line: IEN^NAME
    DataMapper.define(:key_list) do |m|
      m.rpc "XU KEY LIST"
      m.field 0, :ien, :integer
      m.field 1, :name
    end

    # XU KEY GRANT — grant result
    DataMapper.define(:key_grant) do |m|
      m.rpc "XU KEY GRANT"
      m.field 0, :success, :boolean
      m.field 1, :message
    end

    # XU KEY REVOKE — revoke result
    DataMapper.define(:key_revoke) do |m|
      m.rpc "XU KEY REVOKE"
      m.field 0, :success, :boolean
      m.field 1, :message
    end

    # ========================================================================
    # PHARMACY / E-PRESCRIBING (PSO*)
    # ========================================================================

    # PSO NEW RX — new prescription result
    DataMapper.define(:prescription_new) do |m|
      m.rpc "PSO NEW RX"
      m.field 0, :success, :boolean
      m.field 1, :rx_ien_or_error
    end

    # PSO ERX STATUS — e-prescribe status
    DataMapper.define(:erx_status) do |m|
      m.rpc "PSO ERX STATUS"
      m.field 0, :status
      m.field 1, :message
    end

    # PSO CANCEL RX — cancellation result
    DataMapper.define(:prescription_cancel) do |m|
      m.rpc "PSO CANCEL RX"
      m.field 0, :success, :boolean
      m.field 1, :message
    end

    # ========================================================================
    # TIU NOTE TEMPLATES (TIU TEMPLATE*)
    # ========================================================================
    # Field positions are best-effort pending wider trace capture. Templates
    # form a tree (roots → items) with each leaf carrying boilerplate text.

    DataMapper.define(:template_roots) do |m|
      m.rpc "TIU TEMPLATE GETROOTS"
      m.field 0, :ien, :integer
      m.field 1, :name
      m.field 2, :type
    end

    DataMapper.define(:template_items) do |m|
      m.rpc "TIU TEMPLATE GETITEMS"
      m.field 0, :ien, :integer
      m.field 1, :name
      m.field 2, :type
      m.field 3, :parent_ien, :integer
    end

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
    # Field positions are best-effort pending wider trace capture.

    DataMapper.define(:tiu_create_record) do |m|
      m.rpc "TIU CREATE RECORD"
      m.scalar :note_ien
    end

    DataMapper.define(:tiu_documents_by_context) do |m|
      m.rpc "TIU DOCUMENTS BY CONTEXT"
      m.field 0, :ien, :integer
      m.field 1, :title
      m.field 2, :status
      m.field 3, :datetime, :fileman_datetime
      m.field 4, :author_duz
      m.field 5, :author_name
    end

    DataMapper.define(:tiu_get_record_text) do |m|
      m.rpc "TIU GET RECORD TEXT"
      m.text_blob :body
    end

    DataMapper.define(:tiu_authorization) do |m|
      m.rpc "TIU AUTHORIZATION"
      m.scalar :allowed, :boolean
    end

    DataMapper.define(:tiu_lock_record) do |m|
      m.rpc "TIU LOCK RECORD"
      m.scalar :locked, :boolean
    end

    DataMapper.define(:tiu_unlock_record) do |m|
      m.rpc "TIU UNLOCK RECORD"
      m.scalar :unlocked, :boolean
    end

    DataMapper.define(:tiu_set_document_text) do |m|
      m.rpc "TIU SET DOCUMENT TEXT"
      m.scalar :result
    end

    # ========================================================================
    # E-SIGNATURE (ORWU VALIDSIG, TIU SIGN RECORD)
    # ========================================================================

    DataMapper.define(:tiu_valid_signature) do |m|
      m.rpc "ORWU VALIDSIG"
      m.scalar :valid, :boolean
    end

    DataMapper.define(:tiu_sign_record) do |m|
      m.rpc "TIU SIGN RECORD"
      m.scalar :result
    end

    # TIU WHICH SIGNATURE ACTION — server-side authoritative answer to
    # "what signing action is this user allowed to take on this note?".
    # Returns a code like S/C/A/empty; mapped to a symbol by the API.
    DataMapper.define(:tiu_which_signature_action) do |m|
      m.rpc "TIU WHICH SIGNATURE ACTION"
      m.scalar :code
    end

    # ========================================================================
    # ORDERS (ORWOR*, ORWORR*)
    # ========================================================================
    # Field positions are best-effort pending wider trace capture.

    DataMapper.define(:orders_unsigned) do |m|
      m.rpc "ORWOR UNSIGN"
      m.field 0, :ien, :integer
      m.field 1, :patient_dfn, :integer
      m.field 2, :patient_name
      m.field 3, :order_text
      m.field 4, :status
      m.field 5, :datetime, :fileman_datetime
    end

    DataMapper.define(:orders_list) do |m|
      m.rpc "ORWORR AGET"
      m.field 0, :ien, :integer
      m.field 1, :order_text
      m.field 2, :status
      m.field 3, :datetime, :fileman_datetime
      m.field 4, :provider_duz
      m.field 5, :provider_name
    end

    # ORWOR VWGET and ORWORR GET4LST are referenced in the issue trace
    # alongside AGET. AGET alone is sufficient for the symbolic
    # "list orders for patient at view+status" contract this module
    # exposes — the two-step VWGET->AGET pattern is a desktop-client
    # optimization that can be added when a real engine consumer needs
    # the cached view spec or per-group detail. Not modeling speculatively.

    # ORWOR RESULT — result text for a single order IEN. Word-processing
    # shape (global array): the gateway returns a multi-line blob.
    DataMapper.define(:order_result) do |m|
      m.rpc "ORWOR RESULT"
      m.text_blob :result_text
    end

    # ORWOR RESULT HISTORY — historical result values for an order IEN.
    # Caret-delimited rows; positions best-effort pending wider trace
    # capture, but the engine-facing contract is a list of result
    # observations rather than the raw broker shape.
    DataMapper.define(:order_result_history) do |m|
      m.rpc "ORWOR RESULT HISTORY"
      m.field 0, :result_datetime, :fileman_datetime
      m.field 1, :value
      m.field 2, :units
      m.field 3, :abnormal_flag
      m.field 4, :reference_range
      m.field 5, :status
    end

    # ORWOR ACTION TEXT — text describing the user-facing action available
    # on an order (release, sign, discontinue, etc). Takes ORDER_IEN and
    # the action code; returns a free-text blob.
    DataMapper.define(:order_action_text) do |m|
      m.rpc "ORWOR ACTION TEXT"
      m.text_blob :action_text
    end

    # ORWOR EXPIRED — boolean (1/0) for whether an order IEN is expired.
    DataMapper.define(:order_expired) do |m|
      m.rpc "ORWOR EXPIRED"
      m.scalar :expired, :boolean
    end

    # ORWOR SHEETS — order sheets available for a patient (active, delayed
    # release, transfer, etc). One row per sheet: IEN^NAME^TYPE^STATUS.
    DataMapper.define(:order_sheets) do |m|
      m.rpc "ORWOR SHEETS"
      m.field 0, :ien, :integer
      m.field 1, :name
      m.field 2, :sheet_type
      m.field 3, :status
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
    # Field positions are best-effort pending wider trace capture.

    DataMapper.define(:symptom_search) do |m|
      m.rpc "ORWDAL32 SYMPTOMS"
      m.field 0, :ien, :integer
      m.field 1, :name
      m.field 2, :snomed_code
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
  end
end
