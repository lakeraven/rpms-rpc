# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/health_factor"

class HealthFactorTest < Minitest::Test
  DFN       = "8791"
  VISIT_IEN = "2090059"
  FACTOR    = "TOBACCO USE"

  def teardown
    RpmsRpc.reset!
  end

  def test_add_returns_success_with_saved_ien
    RpmsRpc.mock! do |m|
      m.seed_scalar(:visit_data_save, DFN, "8001")
    end

    result = RpmsRpc::HealthFactor.add(DFN, VISIT_IEN, FACTOR, level: "HEAVY")
    assert result[:success]
    assert_equal 8001, result[:ien]
  end

  def test_add_dispatches_bgovupd_set_with_hf_record_type_and_level
    RpmsRpc.mock! do |m|
      m.seed_scalar(:visit_data_save, DFN, "8001")
    end

    RpmsRpc::HealthFactor.add(DFN, VISIT_IEN, FACTOR, level: "MODERATE", narrative: "patient self-reported")

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGOVUPD SET" }
    refute_nil call
    assert_equal DFN, call[:params][0]
    assert_equal VISIT_IEN, call[:params][1]
    assert_match(/\AHF\^/, call[:params][2])
    assert_includes call[:params][2], FACTOR
    assert_includes call[:params][2], "MODERATE"
    assert_includes call[:params][2], "patient self-reported"
  end

  def test_level_is_required_keyword
    assert_raises(ArgumentError) { RpmsRpc::HealthFactor.add(DFN, VISIT_IEN, FACTOR) }
  end

  def test_blank_args_return_failure
    refute RpmsRpc::HealthFactor.add(nil, VISIT_IEN, FACTOR, level: "HEAVY")[:success]
    refute RpmsRpc::HealthFactor.add(DFN, "0", FACTOR, level: "HEAVY")[:success]
    refute RpmsRpc::HealthFactor.add(DFN, VISIT_IEN, "", level: "HEAVY")[:success]
  end
end
