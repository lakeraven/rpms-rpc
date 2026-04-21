# frozen_string_literal: true

require_relative "data_mapper"

# Built-in RPMS RPC response mappings.
#
# Each mapping declares the caret-delimited field positions for a specific
# RPC response format. Gateways use these to parse responses into hashes
# without hand-written split/index code.
#
# Mappings are registered in the DataMapper registry and looked up by name:
#
#   RpmsRpc::DataMapper[:patient_select].parse_one(response, extras: { dfn: 42 })
#
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

    # ORWPT ID INFO — extended patient demographics
    # Format: NAME^SEX^DOB^SSN^RACE^ADDRESS^CITY^STATE^ZIP^PHONE^TRIBAL_NUM^SERVICE_AREA^COVERAGE
    DataMapper.define(:patient_id_info) do |m|
      m.rpc "ORWPT ID INFO"
      m.field 4,  :race
      m.field 5,  :address_line1
      m.field 6,  :city
      m.field 7,  :state
      m.field 8,  :zip_code
      m.field 9,  :phone
      m.field 10, :tribal_enrollment_number
      m.field 11, :service_area
      m.field 12, :coverage_type
    end

    # ORWPT LIST ALL — patient search results (multi-line)
    # Format per line: DFN^NAME
    DataMapper.define(:patient_list) do |m|
      m.rpc "ORWPT LIST ALL"
      m.field 0, :dfn, :integer
      m.field 1, :name
    end

    # ORWPT FULLSSN — SSN lookup
    # Format: DFN^NAME^DOB_TEXT^SSN
    DataMapper.define(:patient_ssn) do |m|
      m.rpc "ORWPT FULLSSN"
      m.field 0, :dfn,  :integer
      m.field 1, :name
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
      m.field 3, :icd_code
      m.field 4, :onset_date,    :fileman_date
      m.field 5, :recorded_date, :fileman_date
      m.field 6, :provider_duz
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

    # BHDPTRPC TRIBAL — tribal enrollment details
    # Format: ENROLLMENT_NUMBER^TRIBE_NAME^ENROLLMENT_DATE^STATUS^SERVICE_UNIT^TRIBE_CODE
    DataMapper.define(:tribal_enrollment) do |m|
      m.rpc "BHDPTRPC TRIBAL"
      m.field 0, :enrollment_number
      m.field 1, :tribe_name
      m.field 2, :enrollment_date, :fileman_date
      m.field 3, :status
      m.field 4, :service_unit
      m.field 5, :tribe_code
    end

    # BHDPTRPC TRIBALVAL — tribal enrollment validation
    # Format: VALID^TRIBE_CODE^ENROLLMENT_NUMBER^STATUS^MESSAGE
    DataMapper.define(:tribal_validation) do |m|
      m.rpc "BHDPTRPC TRIBALVAL"
      m.field 0, :valid,             :boolean
      m.field 1, :tribe_code
      m.field 2, :enrollment_number
      m.field 3, :status
      m.field 4, :message
    end

    # BHDPTRPC TRIBELIST — tribe info lookup
    # Format: IEN^NAME^CODE^SERVICE_UNIT^REGION^AREA
    DataMapper.define(:tribe_info) do |m|
      m.rpc "BHDPTRPC TRIBELIST"
      m.field 0, :ien,          :integer
      m.field 1, :name
      m.field 2, :code
      m.field 3, :service_unit
      m.field 4, :region
      m.field 5, :area
    end

    # BHDPTRPC TRIBALELG — enrollment eligibility
    # Format: ACTIVE^ELIGIBLE_FOR_IHS^SERVICE_UNIT^MESSAGE^BENEFIT_PACKAGE
    DataMapper.define(:enrollment_eligibility) do |m|
      m.rpc "BHDPTRPC TRIBALELG"
      m.field 0, :active,          :boolean
      m.field 1, :eligible_for_ihs, :boolean
      m.field 2, :service_unit
      m.field 3, :message
      m.field 4, :benefit_package
    end

    # BHDPTRPC SU — service unit lookup
    # Format: SERVICE_UNIT_IEN^SERVICE_UNIT_NAME^REGION
    DataMapper.define(:service_unit) do |m|
      m.rpc "BHDPTRPC SU"
      m.field 0, :ien,    :integer
      m.field 1, :name
      m.field 2, :region
    end

    # BHDPTRPC REGISTER — patient registration result
    # Format: "1^DFN" (success) or "0^error_message" (failure)
    DataMapper.define(:patient_register) do |m|
      m.rpc "BHDPTRPC REGISTER"
      m.field 0, :success, :boolean
      m.field 1, :dfn_or_error
    end

    # BHDPTRPC UPDATE — patient update result
    # Format: "1^" (success) or "0^error_message" (failure)
    DataMapper.define(:patient_update) do |m|
      m.rpc "BHDPTRPC UPDATE"
      m.field 0, :success, :boolean
      m.field 1, :error
    end

    # BHDPTRPC NEWVISIT — encounter creation result
    # Format: "1^VISIT_IEN" (success) or "0^error_message" (failure)
    DataMapper.define(:encounter_create) do |m|
      m.rpc "BHDPTRPC NEWVISIT"
      m.field 0, :success,   :boolean
      m.field 1, :visit_ien_or_error
    end

    # ========================================================================
    # PRACTITIONER (ORWU*)
    # ========================================================================

    # ORWU USERINFO — practitioner demographics
    # Format: NAME^TITLE^SERVICE_SECTION^SPECIALTY^NPI^DEA^PHONE^PROVIDER_CLASS^SERVICE
    DataMapper.define(:practitioner_info) do |m|
      m.rpc "ORWU USERINFO"
      m.field 0, :name
      m.field 1, :title
      m.field 2, :service_section
      m.field 3, :specialty
      m.field 4, :npi
      m.field 5, :dea_number
      m.field 6, :phone
      m.field 7, :provider_class
    end

    # ORWU NEWPERS — practitioner search results (multi-line)
    # Format per line: IEN^NAME^TITLE
    DataMapper.define(:practitioner_list) do |m|
      m.rpc "ORWU NEWPERS"
      m.field 0, :ien, :integer
      m.field 1, :name
      m.field 2, :title
    end

    # ========================================================================
    # CLINICAL DATA (ORQQPS*, ORQQCP*, ORQQCT*, ORQQGO*, ORWPCE*)
    # ========================================================================

    # ORQQPS LIST — medication list (multi-line)
    # Format: IEN^DRUG_NAME^SIG^STATUS^LAST_FILL^REFILLS^PROVIDER
    DataMapper.define(:medication_list) do |m|
      m.rpc "ORQQPS LIST"
      m.field 0, :ien
      m.field 1, :drug_name
      m.field 2, :sig
      m.field 3, :status
      m.field 4, :last_fill,   :fileman_date
      m.field 5, :refills,     :integer
      m.field 6, :provider
    end

    # ORQQCP LIST — care plan list (multi-line)
    # Format: IEN^TITLE^STATUS^START_DATE^AUTHOR
    DataMapper.define(:care_plan_list) do |m|
      m.rpc "ORQQCP LIST"
      m.field 0, :ien
      m.field 1, :title
      m.field 2, :status
      m.field 3, :start_date, :fileman_date
      m.field 4, :author
    end

    # ORQQCT LIST — care team list (multi-line)
    # Format: IEN^NAME^ROLE^START_DATE
    DataMapper.define(:care_team_list) do |m|
      m.rpc "ORQQCT LIST"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :role
      m.field 3, :start_date, :fileman_date
    end

    # ORQQGO LIST — goal list (multi-line)
    # Format: IEN^DESCRIPTION^STATUS^TARGET_DATE
    DataMapper.define(:goal_list) do |m|
      m.rpc "ORQQGO LIST"
      m.field 0, :ien
      m.field 1, :description
      m.field 2, :status
      m.field 3, :target_date, :fileman_date
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
    # Format: IEN^DEVICE_NAME^IMPLANT_DATE^STATUS^UDI
    DataMapper.define(:device_list) do |m|
      m.rpc "ORWPCE IMPLANT LIST"
      m.field 0, :ien
      m.field 1, :device_name
      m.field 2, :implant_date, :fileman_date
      m.field 3, :status
      m.field 4, :udi
    end

    # ========================================================================
    # LAB & RADIOLOGY (ORWLRR*, ORWRA*)
    # ========================================================================

    # ORWLRR RESULT LIST — lab result list (multi-line)
    # Format: IEN^TEST_NAME^RESULT^UNITS^REF_RANGE^FLAG^DATE
    DataMapper.define(:lab_result_list) do |m|
      m.rpc "ORWLRR RESULT LIST"
      m.field 0, :ien
      m.field 1, :test_name
      m.field 2, :result
      m.field 3, :units
      m.field 4, :ref_range
      m.field 5, :flag
      m.field 6, :date, :fileman_date
    end

    # ORWRA REPORT LIST — radiology report list (multi-line)
    # Format: IEN^EXAM_NAME^DATE^STATUS^IMPRESSION
    DataMapper.define(:radiology_list) do |m|
      m.rpc "ORWRA REPORT LIST"
      m.field 0, :ien
      m.field 1, :exam_name
      m.field 2, :date,   :fileman_date
      m.field 3, :status
      m.field 4, :impression
    end

    # ========================================================================
    # LOCATION & ORGANIZATION (BHDO*)
    # ========================================================================

    # BHDO HOSP LOC DATA — hospital location
    # Format: IEN^NAME^ABBREVIATION^TYPE^DIVISION
    DataMapper.define(:hospital_location) do |m|
      m.rpc "BHDO HOSP LOC DATA"
      m.field 0, :ien, :integer
      m.field 1, :name
      m.field 2, :abbreviation
      m.field 3, :type
      m.field 4, :division
    end

    # BHDO INST DATA — institution data
    # Format: IEN^NAME^STATION_NUMBER^ADDRESS^CITY^STATE^ZIP^PHONE
    DataMapper.define(:institution) do |m|
      m.rpc "BHDO INST DATA"
      m.field 0, :ien, :integer
      m.field 1, :name
      m.field 2, :station_number
      m.field 3, :address
      m.field 4, :city
      m.field 5, :state
      m.field 6, :zip_code
      m.field 7, :phone
    end

    # ========================================================================
    # SERVICE REQUESTS / REFERRALS (BMCRPC*)
    # ========================================================================

    # BMCRPC SRCHREF — referral search (multi-line)
    # Format: IEN^PATIENT_DFN^STATUS^TYPE^DATE^PROVIDER
    DataMapper.define(:referral_search) do |m|
      m.rpc "BMCRPC SRCHREF"
      m.field 0, :ien
      m.field 1, :patient_dfn, :integer
      m.field 2, :status
      m.field 3, :type
      m.field 4, :date,     :fileman_date
      m.field 5, :provider
    end

    # BMCRPC GTSITPRM — RCIS site parameters
    DataMapper.define(:site_params) do |m|
      m.rpc "BMCRPC GTSITPRM"
      m.field 0, :site_name
      m.field 1, :station_number
      m.field 2, :service_area
    end

    # ========================================================================
    # AUTHENTICATION (XUS*)
    # ========================================================================

    # XUS GET USER INFO — authenticated user info
    # Format: DUZ^NAME^USERCL^CANSIGN^ISPROVIDER^ORDERROLE
    DataMapper.define(:user_info) do |m|
      m.rpc "XUS GET USER INFO"
      m.field 0, :duz, :integer
      m.field 1, :name
      m.field 2, :user_class
      m.field 3, :can_sign,    :boolean
      m.field 4, :is_provider, :boolean
      m.field 5, :order_role
    end

    # ========================================================================
    # HEALTH SUMMARY & REMINDERS (ORWRP*, GMTS*, ORQQPX*)
    # ========================================================================

    # ORWRP TYPES — report type list (multi-line)
    # Format: IEN^NAME
    DataMapper.define(:report_types) do |m|
      m.rpc "ORWRP TYPES"
      m.field 0, :ien, :integer
      m.field 1, :name
    end

    # ORQQPX REMINDERS LIST — clinical reminders (multi-line)
    # Format: IEN^NAME^DUE_DATE^STATUS^LAST_DONE
    DataMapper.define(:reminders_list) do |m|
      m.rpc "ORQQPX REMINDERS LIST"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :due_date,  :fileman_date
      m.field 3, :status
      m.field 4, :last_done, :fileman_date
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
    # Line 1: 0
    # Line 2: 0
    # Line 3: greeting message
    # Line 4: (blank)
    # Line 5: number of tries remaining
    DataMapper.define(:av_code) do |m|
      m.rpc "XUS AV CODE"
      m.line_field 0, :duz, :integer
      m.line_field 3, :greeting
      m.line_field 5, :tries, :integer
    end

    # XUS CVC — CVC verification
    DataMapper.define(:cvc_verify) do |m|
      m.rpc "XUS CVC"
      m.scalar :verified, :boolean
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
    end

    # GMTS PWH REPORT — patient health summary report text
    DataMapper.define(:health_summary_report) do |m|
      m.rpc "GMTS PWH REPORT"
      m.text_blob :report_text
    end

    # GMTS FLOWSHEET LIST — flowsheet items (multi-line)
    DataMapper.define(:flowsheet_list) do |m|
      m.rpc "GMTS FLOWSHEET LIST"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :date, :fileman_date
    end

    # GMTS MAINT ITEMS — maintenance items (multi-line)
    DataMapper.define(:maint_items) do |m|
      m.rpc "GMTS MAINT ITEMS"
      m.field 0, :ien
      m.field 1, :name
    end

    # ORWLRR REPORT — full lab report text
    DataMapper.define(:lab_report) do |m|
      m.rpc "ORWLRR REPORT"
      m.text_blob :report_text
    end

    # ORWLRR REPORT LIST — lab report list (multi-line)
    DataMapper.define(:lab_report_list) do |m|
      m.rpc "ORWLRR REPORT LIST"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :date, :fileman_date
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

    # ORQQCP GET — single care plan
    DataMapper.define(:care_plan_detail) do |m|
      m.rpc "ORQQCP GET"
      m.field 0, :ien
      m.field 1, :title
      m.field 2, :status
      m.field 3, :start_date, :fileman_date
      m.field 4, :author
      m.field 5, :description
    end

    # ORQQCT GET — single care team member
    DataMapper.define(:care_team_detail) do |m|
      m.rpc "ORQQCT GET"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :role
      m.field 3, :start_date, :fileman_date
      m.field 4, :phone
    end

    # ORQQGO GET — single goal
    DataMapper.define(:goal_detail) do |m|
      m.rpc "ORQQGO GET"
      m.field 0, :ien
      m.field 1, :description
      m.field 2, :status
      m.field 3, :target_date, :fileman_date
      m.field 4, :author
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
    DataMapper.define(:device_detail) do |m|
      m.rpc "ORWPCE IMPLANT GET"
      m.field 0, :ien
      m.field 1, :device_name
      m.field 2, :implant_date, :fileman_date
      m.field 3, :status
      m.field 4, :udi
      m.field 5, :manufacturer
    end

    # ========================================================================
    # REFERRAL DETAIL & WRITE RPCs (BMCRPC*)
    # ========================================================================

    # BMCRPC GTRFBYID — single referral detail
    DataMapper.define(:referral_detail) do |m|
      m.rpc "BMCRPC GTRFBYID"
      m.field 0, :ien
      m.field 1, :patient_dfn, :integer
      m.field 2, :status
      m.field 3, :type
      m.field 4, :date,     :fileman_date
      m.field 5, :provider
      m.field 6, :facility
      m.field 7, :notes
    end

    # BMCRPC DELREFRL — referral deletion result
    DataMapper.define(:referral_delete) do |m|
      m.rpc "BMCRPC DELREFRL"
      m.field 0, :success, :boolean
      m.field 1, :message
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

    # BEHOENCX GET SECTION — section data (text blob, parsed by caller)
    DataMapper.define(:section_data) do |m|
      m.rpc "BEHOENCX GET SECTION"
      m.text_blob :section_text
    end

    # BEHOENCX SAVE SECTION — write result
    DataMapper.define(:section_save) do |m|
      m.rpc "BEHOENCX SAVE SECTION"
      m.scalar :success, :boolean
    end

    # BEHOENCX GET SECDEF — section definition (text blob, parsed by caller)
    DataMapper.define(:section_definition) do |m|
      m.rpc "BEHOENCX GET SECDEF"
      m.text_blob :definition_text
    end

    # BEHOENCX LOCK — patient lock result
    DataMapper.define(:patient_lock) do |m|
      m.rpc "BEHOENCX LOCK"
      m.field 0, :success, :boolean
      m.field 1, :lock_id
      m.field 2, :message
    end

    # BEHOENCX UNLOCK — patient unlock (boolean)
    DataMapper.define(:patient_unlock) do |m|
      m.rpc "BEHOENCX UNLOCK"
      m.scalar :success, :boolean
    end

    # ========================================================================
    # SECURITY KEY MANAGEMENT (XU KEY*)
    # ========================================================================

    # XU KEY LIST — key list (multi-line)
    DataMapper.define(:key_list) do |m|
      m.rpc "XU KEY LIST"
      m.field 0, :key_name
      m.field 1, :key_ien, :integer
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
    # PHR / CCD (BEHOCCD*, BPHR*, BEHOCIR*)
    # ========================================================================

    # BEHOCCD PHR — CCD document (text blob)
    DataMapper.define(:ccd_document) do |m|
      m.rpc "BEHOCCD PHR"
      m.text_blob :ccd_xml
    end

    # BEHOCCD GETREF — referral CCD (text blob)
    DataMapper.define(:ccd_referral) do |m|
      m.rpc "BEHOCCD GETREF"
      m.text_blob :ccd_xml
    end

    # BEHOCIR GETTXT — immunization text
    DataMapper.define(:immunization_text) do |m|
      m.rpc "BEHOCIR GETTXT"
      m.text_blob :immunization_text
    end

    # BEHOCIR GETNUM — immunization count
    DataMapper.define(:immunization_count) do |m|
      m.rpc "BEHOCIR GETNUM"
      m.scalar :count, :integer
    end

    # BPHR RECORD ACCESS — PHR access check
    DataMapper.define(:phr_access) do |m|
      m.rpc "BPHR RECORD ACCESS"
      m.scalar :has_access, :boolean
    end

    # BPHR PATIENT DIRECT — patient direct messaging
    DataMapper.define(:phr_patient_direct) do |m|
      m.rpc "BPHR PATIENT DIRECT"
      m.field 0, :direct_address
      m.field 1, :status
    end

    # BPHR PROVIDER DIRECT — provider direct messaging
    DataMapper.define(:phr_provider_direct) do |m|
      m.rpc "BPHR PROVIDER DIRECT"
      m.field 0, :direct_address
      m.field 1, :status
    end

    # BPHR FACILITY DIRECT — facility direct messaging
    DataMapper.define(:phr_facility_direct) do |m|
      m.rpc "BPHR FACILITY DIRECT"
      m.field 0, :direct_address
      m.field 1, :status
    end
  end
end
