# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/data_mapper"
require "rpms_rpc/mappings"

# Tests for DataMapper++ terminology and pointer metadata on field definitions.
class DataMapperMetadataTest < Minitest::Test
  # =============================================================================
  # FIELD METADATA DSL
  # =============================================================================

  def test_field_accepts_terminology_option
    mapping = build_mapping do
      rpc "TEST RPC"
      field 0, :diagnosis, :string, terminology: :icd10
    end

    f = mapping.fields.first
    assert_equal :icd10, f.terminology
  end

  def test_field_accepts_pointer_option
    mapping = build_mapping do
      rpc "TEST RPC"
      field 0, :provider, :string, pointer: { file: 200 }
    end

    f = mapping.fields.first
    assert_equal({ file: 200 }, f.pointer)
  end

  def test_field_accepts_both_terminology_and_pointer
    mapping = build_mapping do
      rpc "TEST RPC"
      field 0, :diagnosis, :string, terminology: :icd10, pointer: { file: 80 }
    end

    f = mapping.fields.first
    assert_equal :icd10, f.terminology
    assert_equal({ file: 80 }, f.pointer)
  end

  def test_field_defaults_terminology_to_nil
    mapping = build_mapping do
      rpc "TEST RPC"
      field 0, :name, :string
    end

    f = mapping.fields.first
    assert_nil f.terminology
  end

  def test_field_defaults_pointer_to_nil
    mapping = build_mapping do
      rpc "TEST RPC"
      field 0, :name, :string
    end

    f = mapping.fields.first
    assert_nil f.pointer
  end

  # =============================================================================
  # QUERY METHODS ON MAPPING
  # =============================================================================

  def test_terminology_fields_returns_only_fields_with_terminology
    mapping = build_mapping do
      rpc "TEST RPC"
      field 0, :name, :string
      field 1, :diagnosis, :string, terminology: :icd10
      field 2, :status, :string
      field 3, :lab_code, :string, terminology: :loinc
    end

    tf = mapping.terminology_fields
    assert_equal 2, tf.length
    assert_equal :diagnosis, tf[0].attribute
    assert_equal :lab_code, tf[1].attribute
  end

  def test_pointer_fields_returns_only_fields_with_pointer
    mapping = build_mapping do
      rpc "TEST RPC"
      field 0, :name, :string
      field 1, :provider, :string, pointer: { file: 200 }
      field 2, :facility, :string, pointer: { file: 4 }
    end

    pf = mapping.pointer_fields
    assert_equal 2, pf.length
    assert_equal :provider, pf[0].attribute
    assert_equal 200, pf[0].pointer[:file]
    assert_equal :facility, pf[1].attribute
  end

  def test_terminology_fields_returns_empty_when_none
    mapping = build_mapping do
      rpc "TEST RPC"
      field 0, :name, :string
    end

    assert_empty mapping.terminology_fields
  end

  def test_pointer_fields_returns_empty_when_none
    mapping = build_mapping do
      rpc "TEST RPC"
      field 0, :name, :string
    end

    assert_empty mapping.pointer_fields
  end

  # =============================================================================
  # EXISTING BEHAVIOR PRESERVED
  # =============================================================================

  def test_field_with_metadata_still_parses_correctly
    mapping = build_mapping do
      rpc "TEST RPC"
      field 0, :diagnosis, :string, terminology: :icd10, pointer: { file: 80 }
      field 1, :status, :string
    end

    result = mapping.parse_one("E11.9^A")
    assert_equal "E11.9", result[:diagnosis]
    assert_equal "A", result[:status]
  end

  def test_field_with_metadata_still_formats_correctly
    mapping = build_mapping do
      rpc "TEST RPC"
      field 0, :diagnosis, :string, terminology: :icd10
      field 1, :status, :string
    end

    formatted = mapping.format_one({ diagnosis: "E11.9", status: "A" })
    assert_equal "E11.9^A", formatted
  end

  # =============================================================================
  # REAL MAPPINGS HAVE METADATA
  # =============================================================================

  def test_problem_list_has_terminology_on_icd_code
    mapping = RpmsRpc::DataMapper[:problem_list]
    tf = mapping.terminology_fields

    assert tf.any? { |f| f.attribute == :icd_code && f.terminology == :icd10 },
      "problem_list should have :icd10 terminology on :icd_code field"
  end

  def test_problem_list_has_pointer_on_provider_duz
    mapping = RpmsRpc::DataMapper[:problem_list]
    pf = mapping.pointer_fields

    assert pf.any? { |f| f.attribute == :provider_duz && f.pointer[:file] == 200 },
      "problem_list should have pointer to file 200 on :provider_duz field"
  end

  def test_medication_list_has_terminology
    mapping = RpmsRpc::DataMapper[:medication_list]
    tf = mapping.terminology_fields

    assert tf.any? { |f| f.terminology == :rxnorm },
      "medication_list should have :rxnorm terminology"
  end

  def test_allergy_list_is_queryable_for_terminology
    mapping = RpmsRpc::DataMapper[:allergy_list]
    assert mapping.terminology_fields.is_a?(Array)
  end

  private

  def build_mapping(&block)
    m = RpmsRpc::DataMapper::Mapping.new(:test_mapping)
    m.configure(&block)
    m
  end
end
