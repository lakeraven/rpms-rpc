# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/data_mapper"

class RpmsRpc::DataMapperTest < Minitest::Test
  # -- DSL declaration -------------------------------------------------------

  def test_define_creates_a_named_mapping
    mapping = RpmsRpc::DataMapper.define(:patient_select) do
      rpc "ORWPT SELECT"
      field 0, :name
      field 1, :sex
      field 2, :dob, :fileman_date
      field 3, :ssn
      field 14, :age, :integer
    end

    assert_equal :patient_select, mapping.name
    assert_equal "ORWPT SELECT", mapping.rpc_name
    assert_equal 5, mapping.fields.size
  end

  def test_field_stores_position_attribute_and_type
    mapping = RpmsRpc::DataMapper.define(:test) do
      rpc "TEST RPC"
      field 0, :name
      field 2, :dob, :fileman_date
      field 3, :count, :integer
      field 4, :active, :boolean
    end

    f = mapping.fields.first
    assert_equal 0, f.position
    assert_equal :name, f.attribute
    assert_equal :string, f.type

    date_field = mapping.fields.find { |ff| ff.attribute == :dob }
    assert_equal :fileman_date, date_field.type
  end

  # -- Single-line parsing ---------------------------------------------------

  def test_parse_one_extracts_fields_from_caret_delimited_line
    mapping = RpmsRpc::DataMapper.define(:patient_select) do
      rpc "ORWPT SELECT"
      field 0, :name
      field 1, :sex
      field 3, :ssn
    end

    line = "DOE,JOHN^M^2800115^111223333^^^^^^^^^^^^^45"
    result = mapping.parse_one(line)

    assert_equal "DOE,JOHN", result[:name]
    assert_equal "M", result[:sex]
    assert_equal "111223333", result[:ssn]
  end

  def test_parse_one_coerces_integer_fields
    mapping = RpmsRpc::DataMapper.define(:test) do
      rpc "TEST"
      field 0, :count, :integer
    end

    assert_equal 42, mapping.parse_one("42")[:count]
  end

  def test_parse_one_coerces_fileman_date_fields
    mapping = RpmsRpc::DataMapper.define(:test) do
      rpc "TEST"
      field 0, :dob, :fileman_date
    end

    result = mapping.parse_one("2800115")
    assert_equal Date.new(1980, 1, 15), result[:dob]
  end

  def test_parse_one_coerces_boolean_fields
    mapping = RpmsRpc::DataMapper.define(:test) do
      rpc "TEST"
      field 0, :active, :boolean
    end

    assert_equal true, mapping.parse_one("1")[:active]
    assert_equal false, mapping.parse_one("0")[:active]
  end

  def test_parse_one_returns_nil_for_empty_fields
    mapping = RpmsRpc::DataMapper.define(:test) do
      rpc "TEST"
      field 0, :name
      field 1, :ssn
    end

    result = mapping.parse_one("DOE,JOHN^")
    assert_equal "DOE,JOHN", result[:name]
    assert_nil result[:ssn]
  end

  def test_parse_one_handles_array_response
    mapping = RpmsRpc::DataMapper.define(:test) do
      rpc "TEST"
      field 0, :name
    end

    result = mapping.parse_one([ "DOE,JOHN^M" ])
    assert_equal "DOE,JOHN", result[:name]
  end

  def test_parse_one_returns_nil_for_empty_response
    mapping = RpmsRpc::DataMapper.define(:test) do
      rpc "TEST"
      field 0, :name
    end

    assert_nil mapping.parse_one("")
    assert_nil mapping.parse_one(nil)
    assert_nil mapping.parse_one([])
  end

  # -- Multi-line parsing (search results) -----------------------------------

  def test_parse_many_extracts_array_of_hashes
    mapping = RpmsRpc::DataMapper.define(:patient_list) do
      rpc "ORWPT LIST ALL"
      field 0, :dfn, :integer
      field 1, :name
    end

    lines = [ "1^DOE,JOHN", "2^SMITH,JANE" ]
    results = mapping.parse_many(lines)

    assert_equal 2, results.size
    assert_equal 1, results[0][:dfn]
    assert_equal "DOE,JOHN", results[0][:name]
    assert_equal 2, results[1][:dfn]
    assert_equal "SMITH,JANE", results[1][:name]
  end

  def test_parse_many_skips_empty_lines
    mapping = RpmsRpc::DataMapper.define(:test) do
      rpc "TEST"
      field 0, :name
    end

    results = mapping.parse_many([ "DOE,JOHN", "", "SMITH,JANE" ])
    assert_equal 2, results.size
  end

  def test_parse_many_returns_empty_array_for_nil
    mapping = RpmsRpc::DataMapper.define(:test) do
      rpc "TEST"
      field 0, :name
    end

    assert_equal [], mapping.parse_many(nil)
    assert_equal [], mapping.parse_many([])
  end

  # -- Merge (multi-RPC) ----------------------------------------------------

  def test_merge_combines_two_parsed_hashes
    select_mapping = RpmsRpc::DataMapper.define(:merge_test_select) do
      rpc "ORWPT SELECT"
      field 0, :name
      field 1, :sex
    end

    id_info_mapping = RpmsRpc::DataMapper.define(:merge_test_id_info) do
      rpc "ORWPT ID INFO"
      field 4, :race
      field 5, :address_line1
      field 9, :phone
    end

    base = select_mapping.parse_one("DOE,JOHN^M^2800115^111223333")
    extended = id_info_mapping.parse_one("DOE,JOHN^M^2800115^111223333^AMERICAN INDIAN^123 Main St^Anchorage^AK^99501^907-555-1234")

    merged = base.merge(extended)
    assert_equal "DOE,JOHN", merged[:name]
    assert_equal "M", merged[:sex]
    assert_equal "AMERICAN INDIAN", merged[:race]
    assert_equal "123 Main St", merged[:address_line1]
    assert_equal "907-555-1234", merged[:phone]
  end

  # -- Inject extra attributes (e.g. DFN from caller) -----------------------

  def test_parse_one_with_extras_merges_caller_provided_attributes
    mapping = RpmsRpc::DataMapper.define(:test) do
      rpc "TEST"
      field 0, :name
    end

    result = mapping.parse_one("DOE,JOHN", extras: { dfn: 42 })
    assert_equal "DOE,JOHN", result[:name]
    assert_equal 42, result[:dfn]
  end

  # -- Registry lookup -------------------------------------------------------

  def test_registry_stores_and_retrieves_mappings
    RpmsRpc::DataMapper.define(:registry_test) do
      rpc "TEST"
      field 0, :name
    end

    mapping = RpmsRpc::DataMapper[:registry_test]
    assert_equal "TEST", mapping.rpc_name
  end
end
