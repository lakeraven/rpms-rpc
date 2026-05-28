# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/measurement"

class MeasurementTest < Minitest::Test
  DFN       = "8791"
  VISIT_IEN = "2090059"
  TYPE      = "WT"

  def teardown
    RpmsRpc.reset!
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
