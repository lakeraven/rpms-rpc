# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mappings"

class RpmsRpc::FetchApiTest < Minitest::Test
  # Minimal mock RPC client
  class MockClient
    def initialize(responses = {})
      @responses = responses
      @calls = []
    end

    attr_reader :calls

    def call_rpc(rpc_name, *params)
      @calls << [ rpc_name, *params ]
      @responses[rpc_name] || ""
    end
  end

  # -- method-style lookup ---------------------------------------------------

  def test_method_lookup_returns_mapping
    mapping = RpmsRpc::DataMapper.patient_select
    assert_equal "ORWPT SELECT", mapping.rpc_name
  end

  def test_method_lookup_for_all_mappings
    %i[
      patient_select patient_id_info patient_list patient_ssn
      allergy_list problem_list vitals medication_list
      practitioner_info practitioner_list
    ].each do |name|
      assert_respond_to RpmsRpc::DataMapper, name, "DataMapper should respond to .#{name}"
    end
  end

  def test_method_lookup_raises_for_unknown
    assert_raises(NoMethodError) { RpmsRpc::DataMapper.nonexistent_mapping }
  end

  # -- fetch_one -------------------------------------------------------------

  def test_fetch_one_calls_rpc_and_parses
    client = MockClient.new("ORWPT SELECT" => [ "DOE,JOHN^M^2800115^111223333^^^^^^^^^^^45" ])

    result = RpmsRpc::DataMapper.patient_select.fetch_one(client, "1", extras: { dfn: 1 })

    assert_equal [ [ "ORWPT SELECT", "1" ] ], client.calls
    assert_equal "DOE,JOHN", result[:name]
    assert_equal "M", result[:sex]
    assert_equal 1, result[:dfn]
  end

  def test_fetch_one_returns_nil_for_empty_response
    client = MockClient.new("ORWPT SELECT" => "")

    result = RpmsRpc::DataMapper.patient_select.fetch_one(client, "99999")
    assert_nil result
  end

  def test_fetch_one_passes_multiple_params
    client = MockClient.new("ORWPT LIST ALL" => [ "1^DOE,JOHN" ])

    RpmsRpc::DataMapper.patient_list.fetch_one(client, "DOE", "1")
    assert_equal [ [ "ORWPT LIST ALL", "DOE", "1" ] ], client.calls
  end

  # -- fetch_many ------------------------------------------------------------

  def test_fetch_many_calls_rpc_and_parses_array
    client = MockClient.new("ORQQAL LIST" => [ "PENICILLIN^RASH^MODERATE", "ASPIRIN^HIVES^SEVERE" ])

    results = RpmsRpc::DataMapper.allergy_list.fetch_many(client, "1")

    assert_equal [ [ "ORQQAL LIST", "1" ] ], client.calls
    assert_equal 2, results.size
    assert_equal "PENICILLIN", results[0][:allergen]
    assert_equal "ASPIRIN", results[1][:allergen]
  end

  def test_fetch_many_returns_empty_array_for_empty_response
    client = MockClient.new("ORQQAL LIST" => "")

    results = RpmsRpc::DataMapper.allergy_list.fetch_many(client, "1")
    assert_equal [], results
  end

  def test_fetch_many_for_patient_list
    client = MockClient.new("ORWPT LIST ALL" => [ "1^DOE,JOHN", "2^SMITH,JANE" ])

    results = RpmsRpc::DataMapper.patient_list.fetch_many(client, "DOE", "1")

    assert_equal 2, results.size
    assert_equal 1, results[0][:dfn]
    assert_equal "SMITH,JANE", results[1][:name]
  end

  # -- fetch_scalar ----------------------------------------------------------

  def test_fetch_scalar_calls_rpc_and_parses_value
    client = MockClient.new("ORWPT SELCHK" => "1")

    result = RpmsRpc::DataMapper.patient_sensitive.fetch_scalar(client, "1")
    assert_equal true, result
  end

  def test_fetch_scalar_returns_nil_for_empty
    client = MockClient.new("ORWPT SELCHK" => "")

    result = RpmsRpc::DataMapper.patient_sensitive.fetch_scalar(client, "1")
    assert_nil result
  end

  # -- fetch_text ------------------------------------------------------------

  def test_fetch_text_calls_rpc_and_joins_lines
    client = MockClient.new("ORWRP REPORT TEXT" => [ "Line 1", "Line 2", "Line 3" ])

    result = RpmsRpc::DataMapper.report_text.fetch_text(client, "1")
    assert_equal "Line 1\nLine 2\nLine 3", result
  end

  def test_fetch_text_returns_nil_for_empty
    client = MockClient.new("ORWRP REPORT TEXT" => "")

    result = RpmsRpc::DataMapper.report_text.fetch_text(client, "1")
    assert_nil result
  end

  # -- fetch_lines -----------------------------------------------------------

  def test_fetch_lines_calls_rpc_and_parses_by_line
    client = MockClient.new("XUS AV CODE" => [ "101", "0", "0", "Welcome", "", "3" ])

    result = RpmsRpc::DataMapper.av_code.fetch_lines(client, "access;verify")

    assert_equal 101, result[:duz]
    assert_equal "Welcome", result[:greeting]
    assert_equal 3, result[:tries]
  end
end
