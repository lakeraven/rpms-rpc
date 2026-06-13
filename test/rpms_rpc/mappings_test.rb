# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mappings"

class RpmsRpc::MappingsTest < Minitest::Test
  # -- ORWPT SELECT ----------------------------------------------------------

  def test_patient_select_parses_full_response
    m = RpmsRpc::DataMapper[:patient_select]
    result = m.parse_one("DOE,JOHN^M^2800115^111223333^^^^^^^^^^^45", extras: { dfn: 1 })

    assert_equal 1, result[:dfn]
    assert_equal "DOE,JOHN", result[:name]
    assert_equal "M", result[:sex]
    assert_equal Date.new(1980, 1, 15), result[:dob]
    assert_equal "111223333", result[:ssn]
    assert_equal 45, result[:age]
  end

  # -- ORWPT ID INFO ---------------------------------------------------------

  def test_patient_id_info_parses_identifier_fields
    m = RpmsRpc::DataMapper[:patient_id_info]
    # Live shape from staging: SSN^DOB^SEX^RACE_CODE^^SITE_IEN^^NAME
    result = m.parse_one("000009999^2100214^M^N^^7819^^MOUSE,MICKEY M")

    assert_equal "000009999", result[:ssn]
    assert_equal Date.new(1910, 2, 14), result[:dob]
    assert_equal "M", result[:sex]
    assert_equal "N", result[:race_code]
    assert_equal 7819, result[:site_ien]
    assert_equal "MOUSE,MICKEY M", result[:name]
  end

  # -- SELECT + ID INFO merge ------------------------------------------------

  def test_patient_merge
    base = RpmsRpc::DataMapper[:patient_select].parse_one(
      "MOUSE,MICKEY M^M^2100214^000009999^0^7819^^^0^^0^0^^^116^0",
      extras: { dfn: 3 }
    )
    ext = RpmsRpc::DataMapper[:patient_id_info].parse_one(
      "000009999^2100214^M^N^^7819^^MOUSE,MICKEY M"
    )
    merged = base.merge(ext)

    assert_equal 3, merged[:dfn]
    assert_equal "MOUSE,MICKEY M", merged[:name]
    assert_equal "N", merged[:race_code]
    assert_equal 7819, merged[:site_ien]
  end

  # -- ORWPT LIST ALL --------------------------------------------------------

  def test_patient_list
    results = RpmsRpc::DataMapper[:patient_list].parse_many([ "1^DOE,JOHN", "2^SMITH,JANE" ])
    assert_equal 2, results.size
    assert_equal 1, results[0][:dfn]
    assert_equal "SMITH,JANE", results[1][:name]
    assert_nil results[0][:sex]
    assert_nil results[0][:dob]
  end

  def test_patient_list_extended_line
    results = RpmsRpc::DataMapper[:patient_list].parse_many([ "1^DOE,JOHN^M^2800115" ])
    assert_equal 1, results.size
    assert_equal "M", results[0][:sex]
    assert_equal Date.new(1980, 1, 15), results[0][:dob]
  end

  # -- ORWPT FULLSSN ---------------------------------------------------------

  def test_patient_ssn
    # Live shape: DFN^NAME^DOB(fileman)^SSN
    result = RpmsRpc::DataMapper[:patient_ssn].parse_one("42^DOE,JOHN^2800115^111223333")
    assert_equal 42, result[:dfn]
    assert_equal "DOE,JOHN", result[:name]
    assert_equal Date.new(1980, 1, 15), result[:dob]
    assert_equal "111223333", result[:ssn]
  end

  # -- ORWPT APPTLST ---------------------------------------------------------

  def test_patient_appointments
    results = RpmsRpc::DataMapper[:patient_appointments].parse_many([ "3260415.1000^1^Primary Care^KEPT" ])
    assert_equal 1, results.size
    assert_equal "Primary Care", results[0][:location]
    assert_equal "KEPT", results[0][:status]
  end

  # -- ORQQAL LIST -----------------------------------------------------------

  def test_allergy_list
    results = RpmsRpc::DataMapper[:allergy_list].parse_many([ "PENICILLIN^RASH^MODERATE", "ASPIRIN^HIVES^SEVERE" ])
    assert_equal 2, results.size
    assert_equal "PENICILLIN", results[0][:allergen]
    assert_equal "SEVERE", results[1][:severity]
  end

  # -- ORQQPL LIST -----------------------------------------------------------

  def test_problem_list
    result = RpmsRpc::DataMapper[:problem_list].parse_many([ "123^ACTIVE^Diabetes Type 2^E11.9^3200101^3250301^101" ]).first
    assert_equal "123", result[:ien]
    assert_equal "ACTIVE", result[:status]
    assert_equal "E11.9", result[:icd_code]
    assert_equal Date.new(2020, 1, 1), result[:onset_date]
  end

  # -- ORQQVI VITALS ---------------------------------------------------------

  def test_vitals
    results = RpmsRpc::DataMapper[:vitals].parse_many([ "BLOOD PRESSURE^120/80^mmHg^3260401" ])
    assert_equal "BLOOD PRESSURE", results[0][:type]
    assert_equal "120/80", results[0][:value]
  end

  # -- BHDPTRPC TRIBAL -------------------------------------------------------

  def test_tribal_enrollment
    result = RpmsRpc::DataMapper[:tribal_enrollment].parse_one("ANLC-12345^Alaska Native - Anchorage (ANLC)^3200101^ACTIVE^Anchorage^ANLC")
    assert_equal "ANLC-12345", result[:enrollment_number]
    assert_equal "Alaska Native - Anchorage (ANLC)", result[:tribe_name]
    assert_equal "ACTIVE", result[:status]
    assert_equal "ANLC", result[:tribe_code]
  end

  # -- BHDPTRPC TRIBALVAL ----------------------------------------------------

  def test_tribal_validation
    result = RpmsRpc::DataMapper[:tribal_validation].parse_one("1^ANLC^12345^ACTIVE^Valid enrollment")
    assert_equal true, result[:valid]
    assert_equal "ANLC", result[:tribe_code]
    assert_equal "Valid enrollment", result[:message]
  end

  # -- BHDPTRPC TRIBELIST ----------------------------------------------------

  def test_tribe_info
    result = RpmsRpc::DataMapper[:tribe_info].parse_one("100^Alaska Native - Anchorage (ANLC)^ANLC^Anchorage^Alaska^Alaska Area")
    assert_equal 100, result[:ien]
    assert_equal "ANLC", result[:code]
    assert_equal "Alaska Area", result[:area]
  end

  # -- BHDPTRPC TRIBALELG ----------------------------------------------------

  def test_enrollment_eligibility
    result = RpmsRpc::DataMapper[:enrollment_eligibility].parse_one("1^1^Anchorage^Eligible for IHS services^BASIC")
    assert_equal true, result[:active]
    assert_equal true, result[:eligible_for_ihs]
    assert_equal "BASIC", result[:benefit_package]
  end

  # -- BHDPTRPC SU -----------------------------------------------------------

  def test_service_unit
    result = RpmsRpc::DataMapper[:service_unit].parse_one("1^Anchorage^Alaska")
    assert_equal 1, result[:ien]
    assert_equal "Anchorage", result[:name]
    assert_equal "Alaska", result[:region]
  end

  # -- BHDPTRPC REGISTER ----------------------------------------------------

  def test_patient_register_success
    result = RpmsRpc::DataMapper[:patient_register].parse_one("1^42")
    assert_equal true, result[:success]
    assert_equal "42", result[:dfn_or_error]
  end

  def test_patient_register_failure
    result = RpmsRpc::DataMapper[:patient_register].parse_one("0^Duplicate SSN")
    assert_equal false, result[:success]
    assert_equal "Duplicate SSN", result[:dfn_or_error]
  end

  # -- ORWU USERINFO ---------------------------------------------------------

  def test_practitioner_info
    # Live shape from staging (DUZ=1 PROVIDER,TEST). 25 caret pieces;
    # only positions [0]=duz, [1]=name, [2]=user_class, [12]=domain,
    # [23]=site_ien have verified semantics.
    result = RpmsRpc::DataMapper[:practitioner_info].parse_one(
      "1^PROVIDER,TEST^3^1^1^5^0^99999^20^1^1^5^DEMO.IHS.GOV^0^180^^^^0^0^^1^0^8904^"
    )
    assert_equal 1, result[:duz]
    assert_equal "PROVIDER,TEST", result[:name]
    assert_equal 3, result[:user_class]
    assert_equal "DEMO.IHS.GOV", result[:kernel_domain]
    assert_equal 8904, result[:site_ien]
  end

  # -- ORWU NEWPERS ----------------------------------------------------------

  def test_practitioner_list
    # ORWU NEWPERS lines are IEN^NAME on staging. IEN is kept as :string
    # because FileMan permits fractional IENs (e.g., ".5" for Postmaster)
    # that :integer coercion would collapse to 0.
    results = RpmsRpc::DataMapper[:practitioner_list].parse_many(
      [ "101^MARTINEZ,SARAH", "102^CHEN,JAMES", ".5^Postmaster" ]
    )
    assert_equal 3, results.size
    assert_equal "101", results[0][:ien]
    assert_equal "MARTINEZ,SARAH", results[0][:name]
    assert_equal "CHEN,JAMES", results[1][:name]
    assert_equal ".5", results[2][:ien]
    assert_nil results[0][:title]
  end

  def test_user_management_user_list
    results = RpmsRpc::DataMapper[:user_management_user_list].parse_many(
      [ "101^MARTINEZ,SARAH", "102^CHEN,JAMES", ".6^Shared,Mail" ]
    )
    assert_equal 3, results.size
    assert_equal "101", results[0][:duz]
    assert_equal "MARTINEZ,SARAH", results[0][:name]
    assert_equal "CHEN,JAMES", results[1][:name]
    assert_equal ".6", results[2][:duz]
    assert_nil results[0][:title]
  end

  # -- ORQQPS LIST -----------------------------------------------------------

  def test_medication_list
    result = RpmsRpc::DataMapper[:medication_list].parse_many([ "456^METFORMIN 500MG^TAKE ONE TABLET BY MOUTH TWICE DAILY^ACTIVE^3260101^3^MARTINEZ" ]).first
    assert_equal "METFORMIN 500MG", result[:drug_name]
    assert_equal "ACTIVE", result[:status]
    assert_equal 3, result[:refills]
  end

  # -- BHDO HOSP LOC DATA ---------------------------------------------------

  def test_hospital_location
    result = RpmsRpc::DataMapper[:hospital_location].parse_one("1^Primary Care Clinic^PCC^C^101")
    assert_equal 1, result[:ien]
    assert_equal "Primary Care Clinic", result[:name]
    assert_equal "PCC", result[:abbreviation]
  end

  # -- BHDO INST DATA --------------------------------------------------------

  def test_institution
    result = RpmsRpc::DataMapper[:institution].parse_one("1^Alaska Native Medical Center^463^4315 Diplomacy Dr^Anchorage^AK^99508^907-729-1900")
    assert_equal 1, result[:ien]
    assert_equal "463", result[:station_number]
    assert_equal "AK", result[:state]
  end

  def test_site_params
    result = RpmsRpc::DataMapper[:site_params].parse_one("COMMTHRESH^50000")
    assert_equal "COMMTHRESH", result[:key]
    assert_equal "50000", result[:value]
  end

  # -- XUS GET USER INFO -----------------------------------------------------

  def test_user_info
    # XUS GET USER INFO is line-based: one value per response line, not
    # caret-delimited. Live shape against staging.
    result = RpmsRpc::DataMapper[:user_info].parse_lines(
      [ "101", "PROVIDER,TEST", "Adam Adam", "7819^DEMO IHS CLINIC^8904", "", "", "", "30" ]
    )
    assert_equal 101, result[:duz]
    assert_equal "PROVIDER,TEST", result[:name]
    assert_equal "Adam Adam", result[:display_name]
    assert_equal "7819^DEMO IHS CLINIC^8904", result[:current_site]
    assert_equal 30, result[:user_class_ien]
  end

  # -- Scalar RPCs -----------------------------------------------------------

  def test_patient_deceased_scalar
    m = RpmsRpc::DataMapper[:patient_deceased]
    assert_equal Date.new(2025, 3, 15), m.parse_scalar("3250315")
    assert_nil m.parse_scalar("0")
  end

  def test_patient_sensitive_scalar
    m = RpmsRpc::DataMapper[:patient_sensitive]
    assert_equal true, m.parse_scalar("1")
    assert_equal false, m.parse_scalar("0")
  end

  def test_user_has_key_scalar
    m = RpmsRpc::DataMapper[:user_has_key]
    assert_equal true, m.parse_scalar("1")
  end

  # -- Line-based RPCs -------------------------------------------------------

  def test_av_code_line_based
    m = RpmsRpc::DataMapper[:av_code]
    result = m.parse_lines([ "101", "0", "0", "Welcome to RPMS", "", "3" ])
    assert_equal 101, result[:duz]
    assert_equal 0, result[:error_code]
    assert_equal 0, result[:verify_needs_change]
    assert_equal "Welcome to RPMS", result[:message]
    assert_equal 3, result[:user_class]
  end

  def test_av_code_failure
    m = RpmsRpc::DataMapper[:av_code]
    result = m.parse_lines([ "0", "1", "0", "Not a valid ACCESS CODE/VERIFY CODE pair.", "", "" ])
    assert_equal 0, result[:duz]
    assert_equal 1, result[:error_code]
    assert_equal "Not a valid ACCESS CODE/VERIFY CODE pair.", result[:message]
  end

  def test_cvc_verify_line_based
    m = RpmsRpc::DataMapper[:cvc_verify]
    result = m.parse_lines([ "0" ])
    assert_equal 0, result[:result_code]
  end

  # -- Text blob RPCs --------------------------------------------------------

  def test_report_text_blob
    m = RpmsRpc::DataMapper[:report_text]
    text = m.parse_text([ "Patient: DOE,JOHN", "Date: 2025-03-15", "Vitals normal." ])
    assert_equal "Patient: DOE,JOHN\nDate: 2025-03-15\nVitals normal.", text
  end

  def test_health_summary_report_types
    result = RpmsRpc::DataMapper[:report_types].parse_many(
      [ "1^STANDARD^Standard Health Summary^SYSTEM" ]
    ).first

    assert_equal 1, result[:ien]
    assert_equal "STANDARD", result[:name]
    assert_equal "Standard Health Summary", result[:description]
    assert_equal "SYSTEM", result[:owner]
  end

  def test_health_summary_type_components
    result = RpmsRpc::DataMapper[:report_type_components].parse_many(
      [ "10^Demographics^DEM^1" ]
    ).first

    assert_equal 10, result[:ien]
    assert_equal "Demographics", result[:name]
    assert_equal "DEM", result[:abbreviation]
    assert_equal 1, result[:sequence]
  end

  def test_health_summary_reminders
    result = RpmsRpc::DataMapper[:reminders_list].parse_many(
      [ "501^A1C Screening^DUE^^^HIGH" ]
    ).first

    assert_equal 501, result[:ien]
    assert_equal "A1C Screening", result[:name]
    assert_equal "DUE", result[:status]
    assert_equal "HIGH", result[:priority]
  end

  def test_health_summary_flowsheet_list
    result = RpmsRpc::DataMapper[:flowsheet_list].parse_many(
      [ "701^Diabetes Measures^A1C and related measures" ]
    ).first

    assert_equal 701, result[:ien]
    assert_equal "Diabetes Measures", result[:name]
    assert_equal "A1C and related measures", result[:description]
  end

  def test_health_summary_flowsheet_data_blob
    m = RpmsRpc::DataMapper[:flowsheet_data]
    text = m.parse_text([ "Date^A1C", "05/01/2026^7.2" ])
    assert_equal "Date^A1C\n05/01/2026^7.2", text
  end

  def test_health_summary_maintenance_items
    result = RpmsRpc::DataMapper[:maint_items].parse_many(
      [ "601^Diabetes Eye Exam^Preventive^DUE^^^Yearly" ]
    ).first

    assert_equal 601, result[:ien]
    assert_equal "Diabetes Eye Exam", result[:name]
    assert_equal "Preventive", result[:category]
    assert_equal "DUE", result[:status]
    assert_equal "Yearly", result[:frequency]
  end

  def test_lab_report_blob
    m = RpmsRpc::DataMapper[:lab_report]
    text = m.parse_text([ "CBC Results", "WBC: 7.2" ])
    assert_equal "CBC Results\nWBC: 7.2", text
  end

  # -- Write result RPCs -----------------------------------------------------

  def test_referral_delete
    result = RpmsRpc::DataMapper[:referral_delete].parse_one("1^Referral deleted")
    assert_equal true, result[:success]
    assert_equal "Referral deleted", result[:message]
  end

  def test_key_grant
    result = RpmsRpc::DataMapper[:key_grant].parse_one("1^Key granted")
    assert_equal true, result[:success]
  end

  def test_key_list
    result = RpmsRpc::DataMapper[:key_list].parse_many([ "1^XUPROGMODE", "2^PROVIDER" ]).first
    assert_equal 1, result[:ien]
    assert_equal "XUPROGMODE", result[:name]
  end

  def test_prescription_new
    result = RpmsRpc::DataMapper[:prescription_new].parse_one("1^12345")
    assert_equal true, result[:success]
    assert_equal "12345", result[:rx_ien_or_error]
  end

  # -- PHR RPCs --------------------------------------------------------------

  def test_immunization_count
    result = RpmsRpc::DataMapper[:immunization_count].parse_one("5^2")

    assert_equal 5, result[:total]
    assert_equal 2, result[:reconciled]
  end

  def test_vaccine_lot_list
    result = RpmsRpc::DataMapper[:vaccine_lot_list].parse_many(
      [ "101^LOT-A^207^COVID-19 mRNA^PFIZER^59267-1000-01^VFC^ACTIVE^2026-12-31^120^45^55" ]
    ).first

    assert_equal "101", result[:ien]
    assert_equal "LOT-A", result[:lot_number]
    assert_equal "207", result[:vaccine_code]
    assert_equal "COVID-19 mRNA", result[:vaccine_display]
    assert_equal "PFIZER", result[:manufacturer]
    assert_equal "59267-1000-01", result[:ndc_code]
    assert_equal "VFC", result[:funding_source]
    assert_equal "ACTIVE", result[:status]
    assert_equal "2026-12-31", result[:expiration_date]
    assert_equal 120, result[:doses_start]
    assert_equal 45, result[:doses_unused]
    assert_equal "55", result[:facility_ien]
  end

  def test_vaccine_lot_detail
    result = RpmsRpc::DataMapper[:vaccine_lot_detail].parse_one(
      "101^LOT-A^207^COVID-19 mRNA^PFIZER^59267-1000-01^VFC^ACTIVE^2026-12-31^120^45^55"
    )

    assert_equal "101", result[:ien]
    assert_equal "LOT-A", result[:lot_number]
    assert_equal 45, result[:doses_unused]
    assert_equal "55", result[:facility_ien]
  end

  def test_vendor_list
    result = RpmsRpc::DataMapper[:vendor_list].parse_many(
      [ "101^Metro Health Center^FACILITY^Cardiology^1^555-0100^Portland^OR" ]
    ).first

    assert_equal "101", result[:ien]
    assert_equal "Metro Health Center", result[:name]
    assert_equal "FACILITY", result[:type]
    assert_equal "Cardiology", result[:specialty]
    assert_equal true, result[:preferred]
    assert_equal "OR", result[:state]
  end

  def test_vendor_detail
    result = RpmsRpc::DataMapper[:vendor_detail].parse_one(
      "101^Metro Health Center^FACILITY^Cardiology, Internal Medicine^1^555-0100^555-0101^contact@example.invalid^Primary Contact^123 Example Way^Portland^OR^97201^MRI, CT Scan^3240101^3271231^1"
    )

    assert_equal "101", result[:ien]
    assert_equal "Cardiology, Internal Medicine", result[:specialties_raw]
    assert_equal true, result[:preferred]
    assert_equal Date.new(2024, 1, 1), result[:contract_start_date]
    assert_equal Date.new(2027, 12, 31), result[:contract_end_date]
    assert_equal true, result[:active]
  end

  def test_vendor_service_list
    result = RpmsRpc::DataMapper[:vendor_service_list].parse_many(
      [ "101^Metro Health Center^MRI^Radiology^1500.00^1" ]
    ).first

    assert_equal "101", result[:ien]
    assert_equal "MRI", result[:service]
    assert_equal "Radiology", result[:specialty]
    assert_equal "1500.00", result[:rate]
    assert_equal true, result[:preferred]
  end

  def test_vendor_contract_list
    result = RpmsRpc::DataMapper[:vendor_contract_list].parse_many(
      [ "201^101^3240101^3271231^MRI, CT Scan^Multi-year contract" ]
    ).first

    assert_equal "201", result[:id]
    assert_equal "101", result[:vendor_ien]
    assert_equal Date.new(2024, 1, 1), result[:start_date]
    assert_equal Date.new(2027, 12, 31), result[:end_date]
    assert_equal "MRI, CT Scan", result[:services_raw]
  end

  def test_vendor_rate_list
    result = RpmsRpc::DataMapper[:vendor_rate_list].parse_many(
      [ "MRI^1500.00^procedure^3240101" ]
    ).first

    assert_equal "MRI", result[:service]
    assert_equal "1500.00", result[:rate]
    assert_equal "procedure", result[:unit]
    assert_equal Date.new(2024, 1, 1), result[:effective_date]
  end

  def test_phr_access
    result = RpmsRpc::DataMapper[:phr_access].parse_one("1^Patient portal enabled")

    assert_equal true, result[:has_access]
    assert_equal "Patient portal enabled", result[:message]
  end

  # -- RPC names verified against staging file 8994 (2026-06-07) -------------
  # BMC v4.0*13 registers the CHS/PRC referral RPCs with English-name NAMEs;
  # the old BMCRPC* tags appear only as routine entry points. The gem
  # previously declared NAME = routine+tag, which never matched the real
  # broker.

  def test_referral_search_uses_broker_rpc_name
    assert_equal "BMC SEARCH REFERRAL", RpmsRpc::DataMapper[:referral_search].rpc_name
  end

  def test_referral_detail_uses_broker_rpc_name
    assert_equal "BMC GET REFERRAL", RpmsRpc::DataMapper[:referral_detail].rpc_name
  end

  # -- Registry completeness -------------------------------------------------

  def test_all_expected_mappings_registered
    expected = %i[
      patient_select patient_id_info patient_list patient_ssn
      patient_appointments allergy_list problem_list vitals
      tribal_enrollment tribal_validation tribe_info enrollment_eligibility
      service_unit patient_register patient_update encounter_create
      practitioner_info practitioner_list user_management_user_list
      medication_list care_plan_list care_team_list goal_list
      procedure_list device_list lab_result_list radiology_list
      hospital_location institution referral_search site_params
      chs_budget chs_remaining_funds chs_quarterly_allocation
      chs_obligation_list chs_obligation_detail chs_obligation_by_referral
      chs_payment_list
      user_info mailman_message mailman_messages_for_patient mailman_send
      mailman_reply mailman_thread mailman_inbox xqal_alert xqal_mark_read
      xqal_forward report_types reminders_list
      reminder_detail patient_deceased patient_sensitive user_has_key
      signon_setup av_code cvc_verify user_keys
      report_text report_type_components health_summary_report
      flowsheet_list flowsheet_data maint_items lab_report lab_report_list radiology_report
      medication_detail care_plan_detail care_team_detail goal_detail
      procedure_detail device_detail referral_detail referral_delete
      patient_recent patient_save_recent
      section_data section_save section_definition patient_lock patient_unlock
      key_list key_grant key_revoke
      prescription_new erx_status prescription_cancel
      ccd_document ccd_referral immunization_text immunization_count
      immunization_exchange_vxu immunization_exchange_vxq
      immunization_exchange_rsp immunization_exchange_process_result
      immunization_exchange_status
      phr_access phr_record_access phr_patient_direct phr_provider_direct phr_facility_direct
      vfc_eligibility vfc_eligibility_list vaccine_lot_list vaccine_lot_detail
      vendor_list vendor_detail preferred_vendor_list vendor_service_list
      vendor_contract_list vendor_rate_list
    ]

    expected.each do |name|
      assert RpmsRpc::DataMapper[name], "Missing mapping: #{name}"
    end
  end
end
