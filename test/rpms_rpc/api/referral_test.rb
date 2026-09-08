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

  # Referral.create is honestly :not_implemented (#217): its former binding
  # BGOREF SET is the personal REFUSALS writer (SET^BGOREF files ^AUPNPREF —
  # BGOREF.m:8,29), and the real referral writer (BMC ADD REFERRAL =
  # SETREFRL^BMCRPC2, 39 positional formals) is exposed as Referral.add.

  def test_create_is_not_implemented_and_calls_no_rpc
    RpmsRpc.mock!

    result = RpmsRpc::Referral.create(DFN, { specialty: "CARDIOLOGY" })

    refute result[:success]
    assert_equal :not_implemented, result[:error]
    assert_match(/BGOREF SET writes refusals/, result[:message])
    assert_empty RpmsRpc.client.received_calls,
      "create must not touch the broker — BGOREF SET would file a refusal"
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
