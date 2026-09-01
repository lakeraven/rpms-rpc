# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/measurement"

class MeasurementTest < Minitest::Test
  DFN       = "8791"
  VISIT_IEN = "2090059"
  TYPE      = "WT"

  # Broker stub that returns one canned raw response for every RPC —
  # for exercising nil/garbage response paths MockClient can't produce.
  class RawResponseClient
    def initialize(response) = @response = response
    def supports?(*) = true
    def call_rpc(*) = @response
  end

  def teardown
    RpmsRpc.reset!
  end

  def stub_broker_response(response)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = RawResponseClient.new(response) }
  end

  def test_add_returns_success_with_saved_ien
    RpmsRpc.mock! do |m|
      m.seed_scalar(:visit_data_save, DFN, "4001")
    end

    result = RpmsRpc::Measurement.add(DFN, VISIT_IEN, TYPE, 72.5, units: "kg")
    assert result[:success]
    assert_equal 4001, result[:ien]
  end

  def test_add_dispatches_bgovupd_set_with_msr_record_type_value_and_units
    RpmsRpc.mock! do |m|
      m.seed_scalar(:visit_data_save, DFN, "4001")
    end

    RpmsRpc::Measurement.add(DFN, VISIT_IEN, TYPE, 72.5, units: "kg", qualifier: "EST")

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGOVUPD SET" }
    refute_nil call
    assert_match(/\AMSR\^/, call[:params][2])
    assert_includes call[:params][2], TYPE
    assert_includes call[:params][2], "72.5"
    assert_includes call[:params][2], "kg"
    assert_includes call[:params][2], "EST"
  end

  def test_add_supports_ucum_compound_units
    RpmsRpc.mock! do |m|
      m.seed_scalar(:visit_data_save, DFN, "4002")
    end

    result = RpmsRpc::Measurement.add(DFN, VISIT_IEN, "BMI", 28.4, units: "kg/m2")
    assert result[:success]
    payload = RpmsRpc.client.received_calls.last[:params][2]
    assert_includes payload, "kg/m2"
  end

  def test_add_pins_full_msr_record_shape
    RpmsRpc.mock! do |m|
      m.seed_scalar(:visit_data_save, DFN, "4001")
    end

    RpmsRpc::Measurement.add(DFN, VISIT_IEN, TYPE, 72.5, units: "kg", qualifier: "EST")

    call = RpmsRpc.client.received_calls.last
    assert_equal "BGOVUPD SET", call[:rpc]
    assert_equal [ DFN, VISIT_IEN, "MSR^WT^72.5^kg^EST" ], call[:params]
  end

  def test_add_without_qualifier_leaves_trailing_field_empty
    RpmsRpc.mock! do |m|
      m.seed_scalar(:visit_data_save, DFN, "4001")
    end

    RpmsRpc::Measurement.add(DFN, VISIT_IEN, TYPE, 72.5, units: "kg")

    assert_equal "MSR^WT^72.5^kg^", RpmsRpc.client.received_calls.last[:params][2]
  end

  def test_add_result_has_exact_gateway_shape
    RpmsRpc.mock! do |m|
      m.seed_scalar(:visit_data_save, DFN, "4001")
    end

    result = RpmsRpc::Measurement.add(DFN, VISIT_IEN, TYPE, 72.5, units: "kg")
    assert_equal %i[success ien raw], result.keys
    assert_equal "4001", result[:raw]
  end

  def test_add_error_string_response_returns_failure_with_raw
    RpmsRpc.mock! do |m|
      m.seed_scalar(:visit_data_save, DFN, "-1^Measurement type not active")
    end

    result = RpmsRpc::Measurement.add(DFN, VISIT_IEN, TYPE, 72.5, units: "kg")
    refute result[:success]
    assert_nil result[:ien]
    assert_equal "-1^Measurement type not active", result[:raw]
  end

  def test_add_nil_broker_response_does_not_raise
    stub_broker_response(nil)

    result = RpmsRpc::Measurement.add(DFN, VISIT_IEN, TYPE, 72.5, units: "kg")
    assert_equal({ success: false, ien: nil, raw: nil }, result)
  end

  def test_add_garbage_array_response_does_not_raise
    stub_broker_response([ "unexpected", "lines" ])

    result = RpmsRpc::Measurement.add(DFN, VISIT_IEN, TYPE, 72.5, units: "kg")
    refute result[:success]
    assert_nil result[:ien]
  end

  def test_value_required_units_required
    refute RpmsRpc::Measurement.add(DFN, VISIT_IEN, TYPE, nil, units: "kg")[:success]
    refute RpmsRpc::Measurement.add(DFN, VISIT_IEN, TYPE, 70, units: "")[:success]
    refute RpmsRpc::Measurement.add(DFN, VISIT_IEN, "", 70, units: "kg")[:success]
  end

  def test_blank_ids_return_failure
    refute RpmsRpc::Measurement.add(nil, VISIT_IEN, TYPE, 70, units: "kg")[:success]
    refute RpmsRpc::Measurement.add(DFN, "0", TYPE, 70, units: "kg")[:success]
  end
end
