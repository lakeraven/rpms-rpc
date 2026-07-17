# frozen_string_literal: true

require_relative "../data_mapper"

# IHS/RPMS-specific RPC response mappings (B* namespaces, MAGG*, CIAV*).
# These exist only on RPMS installs and stay in rpms-rpc after the
# vista-rpc extraction; registers into the same DataMapper registry as
# mappings/stock_vista.rb. Loaded via `require "rpms_rpc/mappings"` —
# see ../mappings.rb.
module RpmsRpc
  module Mappings
    # ========================================================================
    # PATIENT (ORWPT*, BHDPTRPC*)
    # ========================================================================

    # BEHOPTCX PTINFO — broad patient identity bundle for chart banner
    # Format: NAME^SEX^DOB^SSN^^^^^^^MRN^^^^^^DESIGNATED_TEAM^PRIMARY_PROVIDER^^
    DataMapper.define(:patient_ptinfo) do |m|
      m.backend :rpms
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
      m.backend :rpms
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
      m.backend :rpms
      m.rpc "BEHOCACV CWAD"
      m.scalar :cwad
    end

    # BEHOVM TEMPLATE — vital field definitions for a location (multi-line)
    # Format per line: IEN^DISPLAY_ORDER^NAME^ABBREV^UNITS^LOW^HIGH^PERCENTILE_RPC^REQUIRED^DISPLAY_ROW
    DataMapper.define(:vital_template) do |m|
      m.backend :rpms
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
      m.backend :rpms
      m.rpc "BEHOVM VALIDATE"
      m.scalar :validated_value
    end

    # BEHOVM SAVE — bulk vital save (scalar)
    # Returns "0" for success; non-zero/non-empty for error.
    DataMapper.define(:vital_save) do |m|
      m.backend :rpms
      m.rpc "BEHOVM SAVE"
      m.scalar :result_code
    end

    # BHDPTRPC TRIBAL — tribal enrollment details
    # Format: ENROLLMENT_NUMBER^TRIBE_NAME^ENROLLMENT_DATE^STATUS^SERVICE_UNIT^TRIBE_CODE
    DataMapper.define(:tribal_enrollment) do |m|
      m.backend :rpms
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
      m.backend :rpms
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
      m.backend :rpms
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
      m.backend :rpms
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
      m.backend :rpms
      m.rpc "BHDPTRPC SU"
      m.field 0, :ien,    :integer
      m.field 1, :name
      m.field 2, :region
    end

    # BHDPTRPC REGISTER — patient registration result
    # Format: "1^DFN" (success) or "0^error_message" (failure)
    DataMapper.define(:patient_register) do |m|
      m.backend :rpms
      m.rpc "BHDPTRPC REGISTER"
      m.field 0, :success, :boolean
      m.field 1, :dfn_or_error
    end

    # BHDPTRPC UPDATE — patient update result
    # Format: "1^" (success) or "0^error_message" (failure)
    DataMapper.define(:patient_update) do |m|
      m.backend :rpms
      m.rpc "BHDPTRPC UPDATE"
      m.field 0, :success, :boolean
      m.field 1, :error
    end

    # BHDPTRPC NEWVISIT — encounter creation result
    # Format: "1^VISIT_IEN" (success) or "0^error_message" (failure)
    DataMapper.define(:encounter_create) do |m|
      m.backend :rpms
      m.rpc "BHDPTRPC NEWVISIT"
      m.field 0, :success,   :boolean
      m.field 1, :visit_ien_or_error
    end

    # ========================================================================
    # LOCATION & ORGANIZATION (BHDO*)
    # ========================================================================

    # BHDO HOSP LOC DATA — hospital location
    # Format: IEN^NAME^ABBREVIATION^TYPE^DIVISION
    DataMapper.define(:hospital_location) do |m|
      m.backend :rpms
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
      m.backend :rpms
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
    # SERVICE REQUESTS / REFERRALS (BMC* / BMCRPC*)
    # ========================================================================

    # BMC SEARCH REFERRAL — referral search (multi-line)
    # Format: IEN^PATIENT_DFN^STATUS^TYPE^DATE^PROVIDER
    # Verified on staging file 8994 (2026-06-07): NAME is
    # "BMC SEARCH REFERRAL", tag SRCHREF, routine BMCRPC1.
    DataMapper.define(:referral_search) do |m|
      m.backend :rpms
      m.source "BMCRPC1.m SRCHREF"
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
      m.backend :rpms
      m.rpc "BMC ADD C32 PRINT LOG"
      m.scalar :result
    end

    # BMC ADD REFERRAL — creates a primary CHS/RCIS referral.
    DataMapper.define(:bmc_add_referral) do |m|
      m.backend :rpms
      m.rpc "BMC ADD REFERRAL"
      m.scalar :result
    end

    # BMC ADD SECONDARY REFERRAL — creates a secondary referral on an existing request.
    DataMapper.define(:bmc_add_secondary_referral) do |m|
      m.backend :rpms
      m.rpc "BMC ADD SECONDARY REFERRAL"
      m.scalar :result
    end

    # BMC CHK YEAR SITE PARAM — validates fiscal-year/site RCIS setup.
    DataMapper.define(:bmc_check_year_site_param) do |m|
      m.backend :rpms
      m.rpc "BMC CHK YEAR SITE PARAM"
      m.scalar :result
    end

    # BMC CONSULTATION STATUS UPDATE — updates the linked consultation status.
    DataMapper.define(:bmc_consultation_status_update) do |m|
      m.backend :rpms
      m.rpc "BMC CONSULTATION STATUS UPDATE"
      m.scalar :result
    end

    # BMC GET PURPOSE OF REF API — referral purpose lookup.
    # Common shape: IEN^NAME^CODE; extra pieces remain available through raw RPC calls.
    DataMapper.define(:bmc_purpose_of_referral_list) do |m|
      m.backend :rpms
      m.rpc "BMC GET PURPOSE OF REF API"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :code
    end

    # BMC GET RCIS TEMPLATE DETAIL — template detail text/lines.
    DataMapper.define(:bmc_rcis_template_detail) do |m|
      m.backend :rpms
      m.rpc "BMC GET RCIS TEMPLATE DETAIL"
      m.text_blob :detail
    end

    # BMC GET RCIS TEMPLATE LIST — RCIS template lookup.
    # Common shape: IEN^NAME^TYPE.
    DataMapper.define(:bmc_rcis_template_list) do |m|
      m.backend :rpms
      m.rpc "BMC GET RCIS TEMPLATE LIST"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :type
    end

    # BMC GET REFERENCE DATA — RCIS reference-data lookup.
    # Common shape: IEN^NAME^CODE.
    DataMapper.define(:bmc_reference_data) do |m|
      m.backend :rpms
      m.rpc "BMC GET REFERENCE DATA"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :code
    end

    # BMC GET USERS/PROVIDERS — user/provider lookup.
    # Common shape: DUZ^NAME^TITLE.
    DataMapper.define(:bmc_users_providers) do |m|
      m.backend :rpms
      m.rpc "BMC GET USERS/PROVIDERS"
      m.field 0, :duz
      m.field 1, :name
      m.field 2, :title
    end

    # BMC HEALTH SUMMARY TYPE — health-summary type lookup.
    # Common shape: IEN^NAME^ABBREVIATION.
    DataMapper.define(:bmc_health_summary_type) do |m|
      m.backend :rpms
      m.rpc "BMC HEALTH SUMMARY TYPE"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :abbreviation
    end

    # BMC PATIENT ELIGIBILITY STATUS — CHS/RCIS eligibility status.
    DataMapper.define(:bmc_patient_eligibility_status) do |m|
      m.backend :rpms
      m.rpc "BMC PATIENT ELIGIBILITY STATUS"
      m.field 0, :eligible, :boolean
      m.field 1, :status
      m.field 2, :message
    end

    # BMC PATIENT FACE SHEET — patient context text/lines.
    DataMapper.define(:bmc_patient_face_sheet) do |m|
      m.backend :rpms
      m.rpc "BMC PATIENT FACE SHEET"
      m.text_blob :face_sheet
    end

    # BMC PATIENT HEALTH SUMMARY — patient health-summary text/lines.
    DataMapper.define(:bmc_patient_health_summary) do |m|
      m.backend :rpms
      m.rpc "BMC PATIENT HEALTH SUMMARY"
      m.text_blob :health_summary
    end

    # BMC PRINT REFERRAL — print operation result.
    DataMapper.define(:bmc_print_referral) do |m|
      m.backend :rpms
      m.rpc "BMC PRINT REFERRAL"
      m.scalar :result
    end

    # BMC PROVIDERS — provider lookup.
    # Common shape: DUZ^NAME^TITLE.
    DataMapper.define(:bmc_providers) do |m|
      m.backend :rpms
      m.rpc "BMC PROVIDERS"
      m.field 0, :duz
      m.field 1, :name
      m.field 2, :title
    end

    # BMC REFERRAL STATUS UPDATE — updates the referral status.
    DataMapper.define(:bmc_referral_status_update) do |m|
      m.backend :rpms
      m.rpc "BMC REFERRAL STATUS UPDATE"
      m.scalar :result
    end

    # BMC SEARCH REFERRED TO — referred-to facility/provider lookup.
    # Common shape: IEN^NAME^TYPE.
    DataMapper.define(:bmc_search_referred_to) do |m|
      m.backend :rpms
      m.rpc "BMC SEARCH REFERRED TO"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :type
    end

    # BMC UPDATE REFERRAL — updates an existing CHS/RCIS referral.
    DataMapper.define(:bmc_update_referral) do |m|
      m.backend :rpms
      m.rpc "BMC UPDATE REFERRAL"
      m.scalar :result
    end

    # BMCRPC GTSITPRM — RCIS site parameters
    # Format per line: KEY^VALUE
    DataMapper.define(:site_params) do |m|
      m.backend :rpms
      m.rpc "BMCRPC GTSITPRM"
      m.field 0, :key
      m.field 1, :value
    end

    # BMCRPC SRCHVEND — CHS vendor search (multi-line)
    # Format: IEN^NAME^TYPE^SPECIALTY^PREFERRED^PHONE^CITY^STATE
    DataMapper.define(:vendor_list) do |m|
      m.backend :rpms
      m.rpc "BMCRPC SRCHVEND"
      # :ien is left as a string — RCIS vendor identifiers are opaque
      # tokens like "VENDOR-001", not numeric IENs (matches the gateway's
      # pick_string of "IEN" / "Id" / "VendorIEN").
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :type
      m.field 3, :specialty
      m.field 4, :preferred, :boolean
      m.field 5, :phone
      m.field 6, :city
      m.field 7, :state
    end

    # BMCRPC GTVEND — single CHS vendor detail
    # Format: IEN^NAME^TYPE^SPECIALTIES^PREFERRED^PHONE^FAX^EMAIL^CONTACT_NAME^
    #         STREET^CITY^STATE^ZIP^CONTRACTED_SERVICES^CONTRACT_START^CONTRACT_END^ACTIVE
    DataMapper.define(:vendor_detail) do |m|
      m.backend :rpms
      m.rpc "BMCRPC GTVEND"
      m.field 0,  :ien
      m.field 1,  :name
      m.field 2,  :type
      m.field 3,  :specialties_raw
      m.field 4,  :preferred, :boolean
      m.field 5,  :phone
      m.field 6,  :fax
      m.field 7,  :email
      m.field 8,  :contact_name
      m.field 9,  :street
      m.field 10, :city
      m.field 11, :state
      m.field 12, :zip
      m.field 13, :contracted_services_raw
      m.field 14, :contract_start_date, :fileman_date
      m.field 15, :contract_end_date, :fileman_date
      m.field 16, :active, :boolean
    end

    # BMCRPC GTPREFVEND — preferred CHS vendors (multi-line)
    # Same response shape as BMCRPC SRCHVEND.
    DataMapper.define(:preferred_vendor_list) do |m|
      m.backend :rpms
      m.rpc "BMCRPC GTPREFVEND"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :type
      m.field 3, :specialty
      m.field 4, :preferred, :boolean
      m.field 5, :phone
      m.field 6, :city
      m.field 7, :state
    end

    # BMCRPC SRCHVEND — CHS vendors offering a service, with rates
    # Format: IEN^NAME^SERVICE^SPECIALTY^RATE^PREFERRED
    DataMapper.define(:vendor_service_list) do |m|
      m.backend :rpms
      m.rpc "BMCRPC SRCHVEND"
      m.field 0, :ien
      m.field 1, :name
      m.field 2, :service
      m.field 3, :specialty
      m.field 4, :rate
      m.field 5, :preferred, :boolean
    end

    # BMCRPC GTCONTRACT — CHS vendor contracts (multi-line)
    # Format: ID^VENDOR_IEN^START_DATE^END_DATE^SERVICES^NOTES
    DataMapper.define(:vendor_contract_list) do |m|
      m.backend :rpms
      m.rpc "BMCRPC GTCONTRACT"
      # Contract :id and :vendor_ien are opaque string identifiers
      # (e.g. "CONTRACT-001", "VENDOR-001"); gateway uses pick_string.
      m.field 0, :id
      m.field 1, :vendor_ien
      m.field 2, :start_date, :fileman_date
      m.field 3, :end_date, :fileman_date
      m.field 4, :services_raw
      m.field 5, :notes
    end

    # BMCRPC GTRATES — CHS vendor contracted rates (multi-line)
    # Format: SERVICE^RATE^UNIT^EFFECTIVE_DATE
    DataMapper.define(:vendor_rate_list) do |m|
      m.backend :rpms
      m.rpc "BMCRPC GTRATES"
      m.field 0, :service
      m.field 1, :rate
      m.field 2, :unit
      m.field 3, :effective_date, :fileman_date
    end

    # BMCRPC GTBUDGET — CHS/PRC budget allocation by fiscal year
    # Format: FISCAL_YEAR^TOTAL_BUDGET^START_DATE^END_DATE
    DataMapper.define(:chs_budget) do |m|
      m.backend :rpms
      m.rpc "BMCRPC GTBUDGET"
      m.field 0, :fiscal_year
      m.field 1, :total_budget
      m.field 2, :start_date, :fileman_date
      m.field 3, :end_date,   :fileman_date
    end

    # BMCRPC GTREMAIN — remaining CHS/PRC funds for a fiscal year
    # Format: REMAINING^OBLIGATED^EXPENDED
    DataMapper.define(:chs_remaining_funds) do |m|
      m.backend :rpms
      m.rpc "BMCRPC GTREMAIN"
      m.field 0, :remaining
      m.field 1, :obligated
      m.field 2, :expended
    end

    # BMCRPC GTQTRALLOC — quarterly CHS/PRC allocation
    # Format: QUARTER^ALLOCATED^SPENT^REMAINING
    DataMapper.define(:chs_quarterly_allocation) do |m|
      m.backend :rpms
      m.rpc "BMCRPC GTQTRALLOC"
      m.field 0, :quarter
      m.field 1, :allocated
      m.field 2, :spent
      m.field 3, :remaining
    end

    # BMCRPC GTOBLIG — CHS/PRC obligation list
    # Format: ID^REFERRAL_IEN^PATIENT_DFN^AMOUNT^STATUS^SERVICE_TYPE^CREATED_DATE
    DataMapper.define(:chs_obligation_list) do |m|
      m.backend :rpms
      m.rpc "BMCRPC GTOBLIG"
      m.field 0, :id
      # :referral_ien and :patient_dfn are opaque string identifiers (the
      # CHS mock fixtures use "REF-001" style tokens, and the rpms_redux
      # gateway calls pick_string on these fields). Coercing to integer
      # would turn legitimate values into 0.
      m.field 1, :referral_ien
      m.field 2, :patient_dfn
      m.field 3, :amount
      m.field 4, :status
      m.field 5, :service_type
      m.field 6, :created_date, :fileman_date
    end

    # BMCRPC GTOBLIGID — single CHS/PRC obligation
    # Format: ID^REFERRAL_IEN^PATIENT_DFN^AMOUNT^AMOUNT_PAID^STATUS^SERVICE_TYPE^VENDOR_ID^CREATED_DATE^PAID_DATE
    DataMapper.define(:chs_obligation_detail) do |m|
      m.backend :rpms
      m.rpc "BMCRPC GTOBLIGID"
      m.field 0, :id
      # :referral_ien and :patient_dfn are opaque string identifiers (the
      # CHS mock fixtures use "REF-001" style tokens, and the rpms_redux
      # gateway calls pick_string on these fields). Coercing to integer
      # would turn legitimate values into 0.
      m.field 1, :referral_ien
      m.field 2, :patient_dfn
      m.field 3, :amount
      m.field 4, :amount_paid
      m.field 5, :status
      m.field 6, :service_type
      m.field 7, :vendor_id
      m.field 8, :created_date, :fileman_date
      m.field 9, :paid_date,    :fileman_date
    end

    # BMCRPC GTREFOBLIG — single CHS/PRC obligation by referral IEN
    DataMapper.define(:chs_obligation_by_referral) do |m|
      m.backend :rpms
      m.rpc "BMCRPC GTREFOBLIG"
      m.field 0, :id
      # :referral_ien and :patient_dfn are opaque string identifiers (the
      # CHS mock fixtures use "REF-001" style tokens, and the rpms_redux
      # gateway calls pick_string on these fields). Coercing to integer
      # would turn legitimate values into 0.
      m.field 1, :referral_ien
      m.field 2, :patient_dfn
      m.field 3, :amount
      m.field 4, :amount_paid
      m.field 5, :status
      m.field 6, :service_type
      m.field 7, :vendor_id
      m.field 8, :created_date, :fileman_date
      m.field 9, :paid_date,    :fileman_date
    end

    # BMCRPC GTPAYMENT — payments against a CHS/PRC obligation
    # Format: ID^OBLIGATION_ID^AMOUNT^PAYMENT_DATE^CHECK_NUMBER^VENDOR_ID^CREATED_DATE
    DataMapper.define(:chs_payment_list) do |m|
      m.backend :rpms
      m.rpc "BMCRPC GTPAYMENT"
      m.field 0, :id
      m.field 1, :obligation_id
      m.field 2, :amount
      m.field 3, :payment_date, :fileman_date
      m.field 4, :check_number
      m.field 5, :vendor_id
      m.field 6, :created_date, :fileman_date
    end

    # ========================================================================
    # REFERRAL DETAIL & WRITE RPCs (BMC* / BMCRPC*)
    # ========================================================================

    # BMC GET REFERRAL — single referral detail
    # Verified on staging file 8994 (2026-06-07): NAME is
    # "BMC GET REFERRAL", tag GTRFBYID, routine BMCRPC1.
    DataMapper.define(:referral_detail) do |m|
      m.backend :rpms
      m.source "BMCRPC1.m GTRFBYID"
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

    # BMCRPC DELREFRL — referral deletion result
    DataMapper.define(:referral_delete) do |m|
      m.backend :rpms
      m.rpc "BMCRPC DELREFRL"
      m.field 0, :success, :boolean
      m.field 1, :message
    end

    # ========================================================================
    # PATIENT RECENT LIST & AGG EDITING (ORWPT*, BEHOENCX*)
    # ========================================================================

    # BEHOENCX GET SECTION — section data (text blob, parsed by caller)
    DataMapper.define(:section_data) do |m|
      m.backend :rpms
      m.rpc "BEHOENCX GET SECTION"
      m.text_blob :section_text
    end

    # BEHOENCX SAVE SECTION — write result
    DataMapper.define(:section_save) do |m|
      m.backend :rpms
      m.rpc "BEHOENCX SAVE SECTION"
      m.scalar :success, :boolean
    end

    # BEHOENCX GET SECDEF — section definition (text blob, parsed by caller)
    DataMapper.define(:section_definition) do |m|
      m.backend :rpms
      m.rpc "BEHOENCX GET SECDEF"
      m.text_blob :definition_text
    end

    # BEHOENCX GETVISIT — core visit detail by visit_ien
    # Format: LOCATION_IEN^DATETIME_RAW^STATUS^PATIENT_DFN^WARD^?
    DataMapper.define(:encounter_visit) do |m|
      m.backend :rpms
      m.rpc "BEHOENCX GETVISIT"
      m.field 0, :location_ien, :integer
      m.field 1, :datetime_raw
      m.field 2, :status
      m.field 3, :patient_dfn, :integer
      m.field 4, :ward
    end

    # BEHOENCX FETCH — hydrated visit context (location + provider names + ward)
    # Format: CLINIC_NAME^CLINIC_ABBREV^^LOCATION_IEN^PROVIDER^VISIT_IEN^WARD^?
    DataMapper.define(:encounter_fetch) do |m|
      m.backend :rpms
      m.rpc "BEHOENCX FETCH"
      m.field 0, :clinic_name
      m.field 1, :clinic_abbrev
      m.field 3, :location_ien, :integer
      m.field 4, :provider
      m.field 5, :visit_ien, :integer
      m.field 6, :ward
    end

    # BEHOENCX CHKVISIT — missing-component report (multi-line)
    # Format per line: COMPONENT^MESSAGE
    DataMapper.define(:encounter_chkvisit) do |m|
      m.backend :rpms
      m.rpc "BEHOENCX CHKVISIT"
      m.field 0, :component
      m.field 1, :message
    end

    # BEHOENCX LOCK — patient lock result
    DataMapper.define(:patient_lock) do |m|
      m.backend :rpms
      m.rpc "BEHOENCX LOCK"
      m.field 0, :success, :boolean
      m.field 1, :lock_id
      m.field 2, :message
    end

    # BEHOENCX UNLOCK — patient unlock (boolean)
    DataMapper.define(:patient_unlock) do |m|
      m.backend :rpms
      m.rpc "BEHOENCX UNLOCK"
      m.scalar :success, :boolean
    end

    # ========================================================================
    # PHR / CCD (BEHOCCD*, BPHR*, BEHOCIR*)
    # ========================================================================

    # BEHOCIR1 GETCCDS — CCD documents for patient
    # Format per line: IEN^DATE^SOURCE^TITLE^TYPE
    DataMapper.define(:ccd_document) do |m|
      m.backend :rpms
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
      m.backend :rpms
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
      m.backend :rpms
      m.rpc "BEHOCIR GETTXT"
      m.text_blob :content
    end

    # BIPC IMMLIST — patient-scoped administered immunization records.
    # Field positions are best-effort pending wider trace capture.
    # Format: IEN^CVX^DISPLAY^STATUS^LOT^EXP^SITE^ROUTE^PRDUZ^PRNAME^OCC^DOSE^UNIT^MFG^VFC^FUND
    DataMapper.define(:immunization_list) do |m|
      m.backend :rpms
      m.rpc "BIPC IMMLIST"
      m.field 0,  :ien
      m.field 1,  :vaccine_code
      m.field 2,  :vaccine_display
      m.field 3,  :status
      m.field 4,  :lot_number
      m.field 5,  :expiration_date,     :fileman_date
      m.field 6,  :site
      m.field 7,  :route
      m.field 8,  :performer_duz, :string, pointer: { file: 200 }
      m.field 9,  :performer_name
      m.field 10, :occurrence_datetime, :fileman_datetime
      m.field 11, :dose_quantity,       :float
      m.field 12, :dose_unit
      m.field 13, :manufacturer
      m.field 14, :vfc_eligibility_code
      m.field 15, :funding_source
    end

    # BIPC IMMGET — single administered immunization record by IEN.
    # Same field shape as :immunization_list.
    DataMapper.define(:immunization_detail) do |m|
      m.backend :rpms
      m.rpc "BIPC IMMGET"
      m.field 0,  :ien
      m.field 1,  :vaccine_code
      m.field 2,  :vaccine_display
      m.field 3,  :status
      m.field 4,  :lot_number
      m.field 5,  :expiration_date,     :fileman_date
      m.field 6,  :site
      m.field 7,  :route
      m.field 8,  :performer_duz, :string, pointer: { file: 200 }
      m.field 9,  :performer_name
      m.field 10, :occurrence_datetime, :fileman_datetime
      m.field 11, :dose_quantity,       :float
      m.field 12, :dose_unit
      m.field 13, :manufacturer
      m.field 14, :vfc_eligibility_code
      m.field 15, :funding_source
    end

    # BEHOCIR GETNUM — CCD count and reconciliation status
    # Format: TOTAL^RECONCILED
    DataMapper.define(:immunization_count) do |m|
      m.backend :rpms
      m.rpc "BEHOCIR GETNUM"
      m.field 0, :total, :integer
      m.field 1, :reconciled, :integer
    end

    # BYIMRT VXU — send patient immunizations to state IIS
    # Format: STATUS^MESSAGE
    DataMapper.define(:immunization_exchange_vxu) do |m|
      m.backend :rpms
      m.rpc "BYIMRT VXU"
      m.field 0, :status_code, :integer
      m.field 1, :message
    end

    # BYIMRT VXQ — submit patient immunization query to state IIS
    # Format: STATUS^MESSAGE
    DataMapper.define(:immunization_exchange_vxq) do |m|
      m.backend :rpms
      m.rpc "BYIMRT VXQ"
      m.field 0, :status_code, :integer
      m.field 1, :message
    end

    # BYIMRT RSP — inbound immunization response lines
    # Format: VACCINE_CODE^VACCINE_DISPLAY^OCCURRENCE_DATE^NDC_CODE^STATUS
    # :occurrence_date is left as a raw string; the API parses it with
    # Date.parse (matches the gateway — values arrive ISO-formatted from
    # the IIS bridge, not FileMan).
    DataMapper.define(:immunization_exchange_rsp) do |m|
      m.backend :rpms
      m.rpc "BYIMRT RSP"
      m.field 0, :vaccine_code
      m.field 1, :vaccine_display
      m.field 2, :occurrence_date
      m.field 3, :ndc_code
      m.field 4, :status
    end

    # BYIMRT RSP — batch process result when called without patient context
    # Format: STATUS^MESSAGE
    DataMapper.define(:immunization_exchange_process_result) do |m|
      m.backend :rpms
      m.rpc "BYIMRT RSP"
      m.field 0, :status_code, :integer
      m.field 1, :message
    end

    # BYIMRT STATUS — IIS exchange connectivity check
    # Format: STATUS^MESSAGE
    DataMapper.define(:immunization_exchange_status) do |m|
      m.backend :rpms
      m.rpc "BYIMRT STATUS"
      m.field 0, :status_code, :integer
      m.field 1, :message
    end

    # BEHOCCD PHR — PHR enrollment/access check
    DataMapper.define(:phr_access) do |m|
      m.backend :rpms
      m.rpc "BEHOCCD PHR"
      m.field 0, :has_access, :boolean
      m.field 1, :message
    end

    # BPHR RECORD ACCESS — records PHR access for reporting
    DataMapper.define(:phr_record_access) do |m|
      m.backend :rpms
      m.rpc "BPHR RECORD ACCESS"
      m.scalar :success, :boolean
    end

    # BPHR PATIENT DIRECT — patient direct messaging
    DataMapper.define(:phr_patient_direct) do |m|
      m.backend :rpms
      m.rpc "BPHR PATIENT DIRECT"
      m.field 0, :direct_address
      m.field 1, :status
    end

    # BPHR PROVIDER DIRECT — provider direct messaging
    DataMapper.define(:phr_provider_direct) do |m|
      m.backend :rpms
      m.rpc "BPHR PROVIDER DIRECT"
      m.field 0, :direct_address
      m.field 1, :status
    end

    # BPHR FACILITY DIRECT — facility direct messaging
    DataMapper.define(:phr_facility_direct) do |m|
      m.backend :rpms
      m.rpc "BPHR FACILITY DIRECT"
      m.field 0, :direct_address
      m.field 1, :status
    end

    # ========================================================================
    # VFC ELIGIBILITY (BIPC*)
    # ========================================================================

    # BIPC ELIGGET — patient VFC eligibility code
    # Format: CODE^LABEL
    DataMapper.define(:vfc_eligibility) do |m|
      m.backend :rpms
      m.rpc "BIPC ELIGGET"
      m.field 0, :code
      m.field 1, :label
    end

    # BIPC ELIGLIST — all VFC eligibility codes (multi-line)
    # Format per line: CODE^LABEL
    DataMapper.define(:vfc_eligibility_list) do |m|
      m.backend :rpms
      m.rpc "BIPC ELIGLIST"
      m.field 0, :code
      m.field 1, :label
    end

    # BIPC LOTLIST — vaccine inventory lots, optionally filtered by facility
    # Format per line: IEN^LOT^CVX^DISPLAY^MANUFACTURER^NDC^SOURCE^STATUS^EXP^START_COUNT^UNUSED^FACILITY
    DataMapper.define(:vaccine_lot_list) do |m|
      m.backend :rpms
      m.rpc "BIPC LOTLIST"
      m.field 0,  :ien
      m.field 1,  :lot_number
      m.field 2,  :vaccine_code
      m.field 3,  :vaccine_display
      m.field 4,  :manufacturer
      m.field 5,  :ndc_code
      m.field 6,  :funding_source
      m.field 7,  :status
      m.field 8,  :expiration_date
      m.field 9,  :doses_start, :integer
      m.field 10, :doses_unused, :integer
      m.field 11, :facility_ien
    end

    # BIPC LOTGET — single vaccine inventory lot
    DataMapper.define(:vaccine_lot_detail) do |m|
      m.backend :rpms
      m.rpc "BIPC LOTGET"
      m.field 0,  :ien
      m.field 1,  :lot_number
      m.field 2,  :vaccine_code
      m.field 3,  :vaccine_display
      m.field 4,  :manufacturer
      m.field 5,  :ndc_code
      m.field 6,  :funding_source
      m.field 7,  :status
      m.field 8,  :expiration_date
      m.field 9,  :doses_start, :integer
      m.field 10, :doses_unused, :integer
      m.field 11, :facility_ien
    end

    # ========================================================================
    # SESSION BOOTSTRAP (CIAVMRPC*, CIAVMCFG*, CIAVCXUS*)
    # ========================================================================

    # CIAVMRPC GETPAR — fetch a CIAVM parameter by name.
    # Used at cold launch to retrieve "CIAVM DEFAULT SOURCE" → config root path.
    DataMapper.define(:session_default_source) do |m|
      m.backend :rpms
      m.rpc "CIAVMRPC GETPAR"
      m.scalar :value, :string
    end

    # CIAVMCFG GETREG — fetch the launching client's registry settings.
    # Field positions are best-effort pending wider trace capture; the RPC
    # returns the registry/config root path used to locate cached config.
    DataMapper.define(:session_registry) do |m|
      m.backend :rpms
      m.rpc "CIAVMCFG GETREG"
      m.field 0, :root
    end

    # CIAVCXUS VIMINFO — fetch the user's launch context (site/division).
    # Field positions are best-effort pending wider trace capture; the RPC
    # carries the user's launch site IEN among other context fields.
    DataMapper.define(:session_vim_info) do |m|
      m.backend :rpms
      m.rpc "CIAVCXUS VIMINFO"
      m.field 0, :site_ien, :integer
      m.field 1, :site_name
      m.field 2, :user_name
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
      m.backend :rpms
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
    # IMAGING CAPABILITIES (MAG*)
    # ========================================================================

    # MAGGUSERKEYS — user's imaging keys (multi-line, one key per line).
    # MAGGUSER2 (per-user permission detail) is referenced in trace but not
    # yet modeled; the boolean predicate derives from key presence alone.
    DataMapper.define(:imaging_user_keys) do |m|
      m.backend :rpms
      m.rpc "MAGGUSERKEYS"
      m.field 0, :key_name
    end

    # ========================================================================
    # PROBLEM LIST WRITE PATHS (BGOPROB*)
    # ========================================================================

    # BGOPROB1 EDPROB — write a problem record (add/edit/delete by action marker
    # in the payload). Returns the new/edited IEN on success; "0" or empty on
    # failure. Wire payload is best-effort pending wider trace capture.
    DataMapper.define(:problem_edit) do |m|
      m.backend :rpms
      m.rpc "BGOPROB1 EDPROB"
      m.scalar :result
    end

    # BGOPROB GET CLASS — problem list filtered by IPL scope class.
    # Same row shape as :problem_list (ORQQPL LIST).
    DataMapper.define(:problem_filter) do |m|
      m.backend :rpms
      m.rpc "BGOPROB GET CLASS"
      m.field 0, :ien
      m.field 1, :status
      m.field 2, :description
      m.field 3, :icd_code, :string, terminology: :icd10
      m.field 4, :onset_date,    :fileman_date
      m.field 5, :recorded_date, :fileman_date
      m.field 6, :provider_duz, :string, pointer: { file: 200 }
    end

    # ========================================================================
    # VISIT DATA ENTRY WRITES (BGOVUPD*, BGOVCPT*, BGOVPOV*)
    # ========================================================================

    # BGOVUPD SET — generic visit-data writer used by POV, health factor,
    # exam component, and measurement entry. Record-type marker is embedded
    # in the payload. Returns the saved IEN on success; "0"/empty on failure.
    # Wire payload is best-effort pending wider trace capture.
    DataMapper.define(:visit_data_save) do |m|
      m.backend :rpms
      m.rpc "BGOVUPD SET"
      m.scalar :result
    end

    # BGOVCPT SET — visit CPT-code save. Returns the saved IEN on success.
    DataMapper.define(:procedure_save) do |m|
      m.backend :rpms
      m.rpc "BGOVCPT SET"
      m.scalar :result
    end

    # ========================================================================
    # REFERRAL CREATE (BGOREF SET)
    # ========================================================================

    DataMapper.define(:referral_create) do |m|
      m.backend :rpms
      m.rpc "BGOREF SET"
      m.scalar :ien
    end

    # ========================================================================
    # NOTIFICATIONS / ALERTS (BQI*)
    # ========================================================================
    # Field positions are best-effort pending wider trace capture.

    DataMapper.define(:notifications_inbox) do |m|
      m.backend :rpms
      m.rpc "BQI GET COMM ALERTS SPLASH"
      m.field 0, :id, :integer
      m.field 1, :type
      m.field 2, :patient_dfn, :integer
      m.field 3, :message
      m.field 4, :severity
      m.field 5, :created_at, :fileman_datetime
      m.field 6, :read_at, :fileman_datetime
    end

    # Mark-read RPC name is a best-guess based on the BQI family; pending
    # wider trace capture, update only the RPC string here if it changes.
    DataMapper.define(:notification_mark_read) do |m|
      m.backend :rpms
      m.rpc "BQI MARK ALERT READ"
      m.scalar :result
    end

    # ========================================================================
    # IMAGING (ORWRA IMAGING*, MAG*)
    # ========================================================================
    # Field positions are best-effort pending wider trace capture.

    # The MAG launch-token RPC is documented as a desktop handoff; the
    # gateway returns the raw token string and lets the engine/integration
    # layer compose the viewer URL.
    DataMapper.define(:image_launch_token) do |m|
      m.backend :rpms
      m.rpc "MAGG IMAGE LAUNCH TOKEN"
      m.scalar :token
    end

    # ========================================================================
    # IMMUNIZATION REFUSAL (BGOREP*)
    # ========================================================================

    DataMapper.define(:immunization_refusal_save) do |m|
      m.backend :rpms
      m.rpc "BGOREP SET"
      m.scalar :result
    end

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
      m.backend :rpms
      m.rpc "BGOTRG GETSUM"
      m.field 0, :id, :integer
      m.field 1, :name
      m.field 2, :status_code
      m.field 3, :priority, :integer
      m.field 4, :due_date, :fileman_date
    end
  end
end
