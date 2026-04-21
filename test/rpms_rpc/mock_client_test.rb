# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"

class RpmsRpc::MockClientTest < Minitest::Test
  # -- format_one (reverse of parse_one) ------------------------------------

  def test_format_one_produces_caret_delimited_string
    mapping = RpmsRpc::DataMapper.patient_select
    result = mapping.format_one({ name: "DOE,JOHN", sex: "M", dob: Date.new(1980, 1, 15), ssn: "111223333", age: 45 })

    # Should produce a string that round-trips through parse_one
    parsed = mapping.parse_one(result)
    assert_equal "DOE,JOHN", parsed[:name]
    assert_equal "M", parsed[:sex]
    assert_equal Date.new(1980, 1, 15), parsed[:dob]
    assert_equal "111223333", parsed[:ssn]
    assert_equal 45, parsed[:age]
  end

  def test_format_one_handles_nil_values
    mapping = RpmsRpc::DataMapper.patient_select
    result = mapping.format_one({ name: "DOE,JOHN", sex: "M" })

    parsed = mapping.parse_one(result)
    assert_equal "DOE,JOHN", parsed[:name]
    assert_nil parsed[:ssn]
  end

  def test_format_many_produces_array_of_strings
    mapping = RpmsRpc::DataMapper.patient_list
    result = mapping.format_many([
      { dfn: 1, name: "DOE,JOHN" },
      { dfn: 2, name: "SMITH,JANE" }
    ])

    assert_equal 2, result.size
    parsed = mapping.parse_many(result)
    assert_equal 1, parsed[0][:dfn]
    assert_equal "SMITH,JANE", parsed[1][:name]
  end

  # -- MockClient seed + call_rpc ------------------------------------------

  def test_seed_and_call_rpc_for_single_record
    mock = RpmsRpc::MockClient.new
    mock.seed(:institution, "1", { ien: 1, name: "ANMC", station_number: "463",
                                   address: "4315 Diplomacy Dr", city: "Anchorage",
                                   state: "AK", zip_code: "99508", phone: "907-729-1900" })

    response = mock.call_rpc("BHDO INST DATA", "1")
    parsed = RpmsRpc::DataMapper.institution.parse_one(response)

    assert_equal 1, parsed[:ien]
    assert_equal "ANMC", parsed[:name]
    assert_equal "AK", parsed[:state]
  end

  def test_call_rpc_returns_empty_for_unknown_key
    mock = RpmsRpc::MockClient.new
    response = mock.call_rpc("BHDO INST DATA", "99999")
    assert_equal "", response
  end

  def test_seed_and_call_rpc_for_patient_select
    mock = RpmsRpc::MockClient.new
    mock.seed(:patient_select, "1", { name: "DOE,JOHN", sex: "M",
                                      dob: Date.new(1980, 1, 15), ssn: "111223333", age: 45 })

    response = mock.call_rpc("ORWPT SELECT", "1")
    parsed = RpmsRpc::DataMapper.patient_select.parse_one(response)

    assert_equal "DOE,JOHN", parsed[:name]
    assert_equal Date.new(1980, 1, 15), parsed[:dob]
  end

  def test_seed_collection_for_search_rpcs
    mock = RpmsRpc::MockClient.new
    mock.seed_collection(:patient_list, [
      { dfn: 1, name: "DOE,JOHN" },
      { dfn: 2, name: "SMITH,JANE" }
    ])

    response = mock.call_rpc("ORWPT LIST ALL", "DOE", "1")
    # Returns all seeded records (filtering is caller's responsibility)
    parsed = RpmsRpc::DataMapper.patient_list.parse_many(response)
    assert_equal 2, parsed.size
  end

  def test_seed_collection_returns_empty_for_unknown_rpc
    mock = RpmsRpc::MockClient.new
    response = mock.call_rpc("ORWPT LIST ALL", "DOE", "1")
    assert_equal "", response
  end

  def test_seed_scalar
    mock = RpmsRpc::MockClient.new
    mock.seed_scalar(:patient_sensitive, "1", true)

    response = mock.call_rpc("ORWPT SELCHK", "1")
    parsed = RpmsRpc::DataMapper.patient_sensitive.parse_scalar(response)
    assert_equal true, parsed
  end

  def test_multiple_seeds_same_rpc_different_keys
    mock = RpmsRpc::MockClient.new
    mock.seed(:patient_select, "1", { name: "DOE,JOHN", sex: "M" })
    mock.seed(:patient_select, "2", { name: "SMITH,JANE", sex: "F" })

    p1 = RpmsRpc::DataMapper.patient_select.parse_one(mock.call_rpc("ORWPT SELECT", "1"))
    p2 = RpmsRpc::DataMapper.patient_select.parse_one(mock.call_rpc("ORWPT SELECT", "2"))

    assert_equal "DOE,JOHN", p1[:name]
    assert_equal "SMITH,JANE", p2[:name]
  end
end
