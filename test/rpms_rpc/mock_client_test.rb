# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/mappings" # MockClient no longer force-loads mappings; seed against them explicitly

class RpmsRpc::MockClientTest < Minitest::Test
  def teardown
    RpmsRpc.reset!
  end

  # -- format round-trip -----------------------------------------------------

  def test_format_one_round_trips_through_parse_one
    mapping = RpmsRpc::DataMapper.patient_select
    formatted = mapping.format_one({ name: "DOE,JOHN", sex: "M", dob: Date.new(1980, 1, 15), ssn: "111223333", age: 45 })
    parsed = mapping.parse_one(formatted)

    assert_equal "DOE,JOHN", parsed[:name]
    assert_equal "M", parsed[:sex]
    assert_equal Date.new(1980, 1, 15), parsed[:dob]
    assert_equal 45, parsed[:age]
  end

  def test_format_one_handles_nil_values
    mapping = RpmsRpc::DataMapper.patient_select
    formatted = mapping.format_one({ name: "DOE,JOHN", sex: "M" })
    parsed = mapping.parse_one(formatted)

    assert_equal "DOE,JOHN", parsed[:name]
    assert_nil parsed[:ssn]
  end

  def test_format_many_round_trips
    mapping = RpmsRpc::DataMapper.patient_list
    formatted = mapping.format_many([ { dfn: 1, name: "DOE,JOHN" }, { dfn: 2, name: "SMITH,JANE" } ])
    parsed = mapping.parse_many(formatted)

    assert_equal 2, parsed.size
    assert_equal 1, parsed[0][:dfn]
    assert_equal "SMITH,JANE", parsed[1][:name]
  end

  # -- MockClient seed + configured fetch ------------------------------------

  def test_seed_and_fetch_one
    RpmsRpc.mock! do |m|
      m.seed(:institution, "1", { ien: 1, name: "ANMC", station_number: "463",
                                  address: "4315 Diplomacy Dr", city: "Anchorage",
                                  state: "AK", zip_code: "99508", phone: "907-729-1900" })
    end

    result = RpmsRpc::DataMapper.institution.fetch_one("1")
    assert_equal 1, result[:ien]
    assert_equal "ANMC", result[:name]
    assert_equal "AK", result[:state]
  end

  def test_fetch_one_returns_nil_for_unknown_key
    RpmsRpc.mock!
    assert_nil RpmsRpc::DataMapper.institution.fetch_one("99999")
  end

  def test_seed_and_fetch_patient
    RpmsRpc.mock! do |m|
      m.seed(:patient_select, "1", { name: "DOE,JOHN", sex: "M", dob: Date.new(1980, 1, 15), ssn: "111223333", age: 45 })
    end

    result = RpmsRpc::DataMapper.patient_select.fetch_one("1")
    assert_equal "DOE,JOHN", result[:name]
    assert_equal Date.new(1980, 1, 15), result[:dob]
  end

  def test_seed_collection_and_fetch_many
    RpmsRpc.mock! do |m|
      m.seed_collection(:patient_list, [ { dfn: 1, name: "DOE,JOHN" }, { dfn: 2, name: "SMITH,JANE" } ])
    end

    results = RpmsRpc::DataMapper.patient_list.fetch_many("", "1")
    assert_equal 2, results.size
  end

  def test_seed_collection_with_filter
    RpmsRpc.mock! do |m|
      m.seed_collection(:patient_list, [
        { dfn: 1, name: "DOE,JOHN" },
        { dfn: 2, name: "SMITH,JANE" },
        { dfn: 3, name: "DOE,JANE" }
      ], filter_field: :name)
    end

    results = RpmsRpc::DataMapper.patient_list.fetch_many("DOE", "1")
    assert_equal 2, results.size

    results = RpmsRpc::DataMapper.patient_list.fetch_many("SMITH", "1")
    assert_equal 1, results.size

    results = RpmsRpc::DataMapper.patient_list.fetch_many("ZZZZZ", "1")
    assert_equal [], results
  end

  def test_seed_scalar_and_fetch
    RpmsRpc.mock! do |m|
      m.seed_scalar(:patient_sensitive, "1", true)
    end

    assert_equal true, RpmsRpc::DataMapper.patient_sensitive.fetch_scalar("1")
  end

  def test_multiple_seeds_same_mapping_different_keys
    RpmsRpc.mock! do |m|
      m.seed(:patient_select, "1", { name: "DOE,JOHN", sex: "M" })
      m.seed(:patient_select, "2", { name: "SMITH,JANE", sex: "F" })
    end

    p1 = RpmsRpc::DataMapper.patient_select.fetch_one("1")
    p2 = RpmsRpc::DataMapper.patient_select.fetch_one("2")

    assert_equal "DOE,JOHN", p1[:name]
    assert_equal "SMITH,JANE", p2[:name]
  end

  def test_seed_and_fetch_allergy_list
    RpmsRpc.mock! do |m|
      m.seed_collection(:allergy_list, [
        { allergen: "PENICILLIN", reaction: "RASH", severity: "MODERATE", allergy_ien: 42 },
        { allergen: "ASPIRIN", reaction: "HIVES", severity: "SEVERE", allergy_ien: 7 }
      ])
    end

    results = RpmsRpc::DataMapper.allergy_list.fetch_many("1")
    assert_equal 2, results.size
    assert_equal "PENICILLIN", results[0][:allergen]
    assert_equal "SEVERE", results[1][:severity]
    assert_equal 7, results[1][:allergy_ien]
  end

  def test_seed_and_fetch_allergy_detail
    RpmsRpc.mock! do |m|
      m.seed(:allergy_detail, "42", {
        allergen: "PENICILLIN",
        originator: "PROVIDER,ONE",
        originator_title: "PHYSICIAN",
        verification_status: "VERIFIED",
        observed_historical: "OBSERVED",
        type: "DRUG",
        observation_date: Date.new(2015, 1, 15),
        severity: "MODERATE",
        drug_class: "PENICILLINS",
        symptoms: "RASH;HIVES",
        comments: "No comments"
      })
    end

    result = RpmsRpc::DataMapper.allergy_detail.fetch_one("42")
    assert_equal "PENICILLIN", result[:allergen]
    assert_equal "VERIFIED", result[:verification_status]
    assert_equal Date.new(2015, 1, 15), result[:observation_date]
    assert_equal "PENICILLINS", result[:drug_class]
  end

  def test_seed_and_fetch_consult_list
    RpmsRpc.mock! do |m|
      m.seed_collection(:consult_list, [
        { ien: 123, request_date: DateTime.new(2015, 1, 15, 8, 30), status: "PENDING", consulting_service: "Cardiology", procedure: "Echocardiogram" },
        { ien: 456, request_date: DateTime.new(2015, 1, 16, 9, 0), status: "ACTIVE", consulting_service: "Orthopedics", procedure: "Knee MRI" }
      ])
    end

    results = RpmsRpc::DataMapper.consult_list.fetch_many("1")
    assert_equal 2, results.size
    assert_equal 123, results[0][:ien]
    assert_equal "PENDING", results[0][:status]
    assert_equal "Cardiology", results[0][:consulting_service]
    assert_equal "Knee MRI", results[1][:procedure]
  end

  def test_seed_and_fetch_consult_detail
    RpmsRpc.mock! do |m|
      m.seed(:consult_detail, "123", {
        entry_date: Date.new(2015, 1, 15),
        patient_dfn: 1,
        to_service: "123.5",
        request_date: Date.new(2015, 1, 15),
        procedure_type: "GMRCOR REQUEST",
        cprs_status: "1",
        sending_provider: "10;PROVIDER,ONE",
        request_type: "P",
        clinically_indicated_date: Date.new(2015, 1, 15)
      })
    end

    result = RpmsRpc::DataMapper.consult_detail.fetch_one("123")
    assert_equal 1, result[:patient_dfn]
    assert_equal "123.5", result[:to_service]
    assert_equal "10;PROVIDER,ONE", result[:sending_provider]
    assert_equal "P", result[:request_type]
  end

  # -- text_blob support -------------------------------------------------------

  def test_seed_text_blob_and_fetch_text
    RpmsRpc.mock! do |m|
      m.seed(:section_data, "1", "Header\nName: DOE,JOHN\nDOB: 01/15/1980")
    end

    text = RpmsRpc::DataMapper.section_data.fetch_text("1")
    assert_includes text, "DOE,JOHN"
    assert_includes text, "Header"
  end

  def test_seed_text_blob_returns_nil_for_unknown_key
    RpmsRpc.mock! do |m|
      m.seed(:section_data, "1", "some text")
    end

    assert_nil RpmsRpc::DataMapper.section_data.fetch_text("999")
  end

  def test_seed_text_blob_with_multiline_content
    content = "ALLERGIES:\n  Penicillin - Hives\n  Shellfish - Anaphylaxis\n\nMEDICATIONS:\n  Lisinopril 10mg"
    RpmsRpc.mock! do |m|
      m.seed(:health_summary_report, "1", content)
    end

    text = RpmsRpc::DataMapper.health_summary_report.fetch_text("1")
    assert_includes text, "Penicillin"
    assert_includes text, "Lisinopril"
  end

  def test_seed_section_definition_text_blob
    RpmsRpc.mock! do |m|
      m.seed(:section_definition, "Header", "1^name^string\n2^dob^date")
    end

    text = RpmsRpc::DataMapper.section_definition.fetch_text("Header")
    assert_includes text, "name"
    assert_includes text, "dob"
  end

  # -- smart seed auto-detection -----------------------------------------------

  def test_seed_auto_detects_text_blob_mapping_with_string
    RpmsRpc.mock! do |m|
      m.seed(:section_data, "1", "raw text content")
    end

    text = RpmsRpc::DataMapper.section_data.fetch_text("1")
    assert_equal "raw text content", text
  end

  def test_seed_auto_detects_scalar_mapping_with_hash
    RpmsRpc.mock! do |m|
      m.seed(:section_save, "1", { success: true })
    end

    result = RpmsRpc::DataMapper.section_save.fetch_scalar("1")
    assert_equal true, result
  end

  def test_seed_field_based_mapping_still_works
    RpmsRpc.mock! do |m|
      m.seed(:patient_select, "99", { name: "TEST,AUTO", sex: "F" })
    end

    p = RpmsRpc::DataMapper.patient_select.fetch_one("99")
    assert_equal "TEST,AUTO", p[:name]
  end
end
