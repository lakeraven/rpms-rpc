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

  def test_add_referral_calls_bmc_add_referral
    RpmsRpc.mock! do |m|
      m.seed_scalar(:bmc_add_referral, "8791", "1^3001")
    end

    result = RpmsRpc::Referral.add(DFN, "44")

    assert result[:success]
    assert_equal "3001", result[:message]
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BMC ADD REFERRAL" }
    assert_equal [ DFN, "44" ], call[:params]
  end

  def test_add_referral_bare_ien_response_preserves_value
    # A BMC RPC that returns a bare IEN like "10" (no STATUS^MESSAGE caret)
    # must not be parsed as `message: "0"`. Only strip a leading 0/1 when
    # followed by `^`.
    RpmsRpc.mock! do |m|
      m.seed_scalar(:bmc_add_referral, "8791", "10")
    end

    result = RpmsRpc::Referral.add(DFN, "44")

    assert result[:success]
    assert_equal "10", result[:message]
  end

  def test_update_referral_status_calls_bmc_status_rpc
    RpmsRpc.mock! do |m|
      m.seed_scalar(:bmc_referral_status_update, "3001", "1^UPDATED")
    end

    result = RpmsRpc::Referral.update_status(3001, "APPROVED", "routine")

    assert result[:success]
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BMC REFERRAL STATUS UPDATE" }
    assert_equal [ "3001", "APPROVED", "routine" ], call[:params]
  end

  def test_reference_data_returns_bmc_lookup_rows
    RpmsRpc.mock! do |m|
      m.seed_collection(:bmc_reference_data, [
        { ien: "10", name: "CARDIOLOGY", code: "CARD" }
      ])
    end

    rows = RpmsRpc::Referral.reference_data("PURPOSE")

    assert_equal 1, rows.length
    assert_equal({ ien: "10", name: "CARDIOLOGY", code: "CARD" }, rows.first)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BMC GET REFERENCE DATA" }
    assert_equal [ "PURPOSE" ], call[:params]
  end

  def test_rcis_template_detail_returns_text_blob
    RpmsRpc.mock! do |m|
      m.seed_text(:bmc_rcis_template_detail, "7", "line one\nline two")
    end

    assert_equal "line one\nline two", RpmsRpc::Referral.rcis_template_detail(7)
  end

  def test_patient_eligibility_status_returns_structured_status
    RpmsRpc.mock! do |m|
      m.seed(:bmc_patient_eligibility_status, DFN, {
        eligible: true,
        status: "ELIGIBLE",
        message: "Active CHS eligibility"
      })
    end

    result = RpmsRpc::Referral.patient_eligibility_status(DFN)

    assert_equal true, result[:eligible]
    assert_equal "ELIGIBLE", result[:status]
  end

  def test_bmc_calls_short_circuit_when_capability_unsupported
    RpmsRpc.mock! do |m|
      m.seed_capability(:bmc_referral_workflow, supported: false)
      m.seed_scalar(:bmc_add_referral, DFN, "1^3001")
      m.seed_collection(:bmc_reference_data, [
        { ien: "10", name: "CARDIOLOGY", code: "CARD" }
      ])
    end

    result = RpmsRpc::Referral.add(DFN)

    refute result[:success]
    assert_match(/not available/i, result[:error])
    assert_equal [], RpmsRpc::Referral.reference_data("PURPOSE")
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc].start_with?("BMC ") }
  end
end
