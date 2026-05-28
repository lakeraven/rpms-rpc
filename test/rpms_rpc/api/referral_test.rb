# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/referral"

class ReferralTest < Minitest::Test
  DFN = "8791"

  def teardown
    RpmsRpc.reset!
  end

  def test_create_returns_success_with_saved_ien
    RpmsRpc.mock! do |m|
      m.seed_scalar(:referral_create, DFN, "3001")
    end

    params = {
      provider_ien: 500,
      specialty: "CARDIOLOGY",
      reason: "AFib evaluation",
      priority: "ROUTINE",
      requested_date: "2026-06-15"
    }
    result = RpmsRpc::Referral.create(DFN, params)

    assert result[:success]
    assert_equal 3001, result[:ien]
  end

  def test_create_dispatches_bgoref_set_with_dfn_and_payload
    RpmsRpc.mock! do |m|
      m.seed_scalar(:referral_create, DFN, "3001")
    end

    RpmsRpc::Referral.create(DFN, {
      provider_ien: 500, specialty: "GI", reason: "polyp follow-up",
      priority: "ROUTINE", requested_date: "2026-07-01"
    })

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGOREF SET" }
    refute_nil call
    assert_equal DFN, call[:params][0]
    assert_includes call[:params][1], "500"
    assert_includes call[:params][1], "GI"
  end

  def test_create_payload_field_order_is_deterministic
    RpmsRpc.mock! do |m|
      m.seed_scalar(:referral_create, DFN, "3001")
    end
    RpmsRpc::Referral.create(DFN, {
      reason: "X", priority: "ROUTINE", provider_ien: 500,
      requested_date: "2026-06-15", specialty: "CARDIO"
    })
    a = RpmsRpc.client.received_calls.last[:params][1]

    RpmsRpc.mock! do |m|
      m.seed_scalar(:referral_create, DFN, "3001")
    end
    RpmsRpc::Referral.create(DFN, {
      provider_ien: 500, specialty: "CARDIO", reason: "X",
      priority: "ROUTINE", requested_date: "2026-06-15"
    })
    b = RpmsRpc.client.received_calls.last[:params][1]

    assert_equal a, b, "payload must not depend on caller's Hash insertion order"
  end

  def test_create_raises_on_non_hash_params
    err = assert_raises(ArgumentError) { RpmsRpc::Referral.create(DFN, "not a hash") }
    assert_match(/must be a Hash/, err.message)
  end

  def test_create_blank_dfn_returns_failure
    result = RpmsRpc::Referral.create(nil, { provider_ien: 1 })
    refute result[:success]
    assert_nil result[:ien]
  end

  def test_create_zero_response_returns_failure
    RpmsRpc.mock! do |m|
      m.seed_scalar(:referral_create, DFN, "0")
    end
    refute RpmsRpc::Referral.create(DFN, { provider_ien: 1 })[:success]
  end
end
