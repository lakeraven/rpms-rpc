# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/eprescribing"

class EprescribingTest < Minitest::Test
  RX_ATTRS = {
    patient_dfn:         "8791",
    medication_code:     "12345",
    medication_display:  "AMOXICILLIN 500MG CAP",
    dosage_instruction:  "1 PO TID",
    route:               "PO",
    frequency:           "TID",
    dispense_quantity:   21,
    refills:             0,
    days_supply:         7,
    pharmacy_ien:        "1",
    requester_duz:       "301"
  }.freeze

  RX_COMPOSITE = "8791^12345^AMOXICILLIN 500MG CAP^1 PO TID^PO^TID^21^0^7^1^301"

  def setup
    RpmsRpc.mock! do |m|
      # PSO NEW RX — success: "1^<tx_id>", failure: "0^<error>"
      m.seed(:prescription_new, RX_COMPOSITE,                { success: true,  rx_ien_or_error: "TX001" })
      m.seed(:prescription_new, "FAIL^x^x^x^x^x^x^x^x^x^x",  { success: false, rx_ien_or_error: "Pharmacy IEN missing" })

      # PSO ERX STATUS — various raw status strings
      m.seed(:erx_status, "TX001",       { status: "delivered",   message: nil })
      m.seed(:erx_status, "TX-SENT",     { status: "sent",        message: nil })
      m.seed(:erx_status, "TX-VOID",     { status: "voided",      message: nil })
      m.seed(:erx_status, "TX-XMIT",     { status: "transmitted", message: nil })
      m.seed(:erx_status, "TX-FAIL",     { status: "failed",      message: "downstream timeout" })
      m.seed(:erx_status, "TX-FAIL-NOMSG", { status: "error",     message: nil })
      m.seed(:erx_status, "TX-WEIRD",    { status: "pending",     message: nil })

      # PSO CANCEL RX — success: "1^Cancelled", failure: "0^<error>"
      m.seed(:prescription_cancel, "TX001",                          { success: true,  message: "Cancelled" })
      m.seed(:prescription_cancel, "TX001^patient request",          { success: true,  message: "Cancelled" })
      m.seed(:prescription_cancel, "TX-NOPE",                        { success: false, message: "Not found" })
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # === transmit ============================================================

  def test_transmit_returns_success_with_transmission_id
    result = RpmsRpc::Eprescribing.transmit(RX_ATTRS)

    assert_equal true,    result[:success]
    assert_equal "TX001", result[:transmission_id]
  end

  def test_transmit_returns_failure_with_error_message
    bad = RX_ATTRS.merge(patient_dfn: "FAIL", medication_code: "x", medication_display: "x",
                         dosage_instruction: "x", route: "x", frequency: "x",
                         dispense_quantity: "x", refills: "x", days_supply: "x",
                         pharmacy_ien: "x", requester_duz: "x")

    result = RpmsRpc::Eprescribing.transmit(bad)

    assert_equal false, result[:success]
    assert_equal "Pharmacy IEN missing", result[:error]
  end

  def test_transmit_returns_failure_for_empty_response
    # Unseeded composite → MockClient returns "" → fetch_one returns nil
    result = RpmsRpc::Eprescribing.transmit(RX_ATTRS.merge(patient_dfn: "UNKNOWN"))

    assert_equal false, result[:success]
    refute_nil result[:error]
  end

  def test_transmit_sends_caret_delimited_composite_to_rpc
    RpmsRpc::Eprescribing.transmit(RX_ATTRS)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "PSO NEW RX" }
    refute_nil call, "Expected PSO NEW RX to fire"
    assert_equal 1, call[:params].length, "PSO NEW RX takes a single composite param"
    assert_equal RX_COMPOSITE, call[:params].first
  end

  def test_transmit_rejects_non_hash_attrs
    [ nil, "string", 42, [ :a, :b ] ].each do |bad|
      result = RpmsRpc::Eprescribing.transmit(bad)
      assert_equal false, result[:success], "transmit(#{bad.inspect}) should fail"
      refute_nil result[:error]
    end
    refute RpmsRpc.client.received_calls.any? { |c| c[:rpc] == "PSO NEW RX" },
      "PSO NEW RX should not fire for non-Hash attrs"
  end

  # === status ==============================================================

  def test_status_returns_canonical_delivered
    assert_equal "delivered", RpmsRpc::Eprescribing.status("TX001")[:status]
  end

  def test_status_maps_sent_to_transmitted
    assert_equal "transmitted", RpmsRpc::Eprescribing.status("TX-SENT")[:status]
  end

  def test_status_passes_transmitted_through_as_transmitted
    assert_equal "transmitted", RpmsRpc::Eprescribing.status("TX-XMIT")[:status]
  end

  def test_status_maps_voided_to_cancelled
    assert_equal "cancelled", RpmsRpc::Eprescribing.status("TX-VOID")[:status]
  end

  def test_status_maps_failed_to_error_and_surfaces_message
    result = RpmsRpc::Eprescribing.status("TX-FAIL")
    assert_equal "error", result[:status]
    assert_equal "downstream timeout", result[:error]
  end

  def test_status_always_includes_error_key_when_status_is_error
    result = RpmsRpc::Eprescribing.status("TX-FAIL-NOMSG")
    assert_equal "error", result[:status]
    assert result.key?(:error),
      ":error key must always be present when status is 'error', even when RPMS sends no message"
    refute_nil result[:error]
  end

  def test_status_returns_queued_for_unknown_status_string
    assert_equal "queued", RpmsRpc::Eprescribing.status("TX-WEIRD")[:status]
  end

  def test_status_returns_error_for_blank_transmission_id
    nil_result = RpmsRpc::Eprescribing.status(nil)
    empty_result = RpmsRpc::Eprescribing.status("")
    assert_equal "error", nil_result[:status]
    assert_equal "error", empty_result[:status]
    refute_nil nil_result[:error]
  end

  def test_status_returns_error_when_no_response
    result = RpmsRpc::Eprescribing.status("TX-UNKNOWN")
    assert_equal "error", result[:status]
  end

  def test_status_rejects_whitespace_only_transmission_id
    result = RpmsRpc::Eprescribing.status("   ")

    assert_equal "error", result[:status]
    refute_nil result[:error]
    refute RpmsRpc.client.received_calls.any? { |c| c[:rpc] == "PSO ERX STATUS" },
      "PSO ERX STATUS should not fire when transmission_id is whitespace-only"
  end

  # === cancel ==============================================================

  def test_cancel_returns_success_without_reason
    result = RpmsRpc::Eprescribing.cancel("TX001")

    assert_equal true, result[:success]
    refute result.key?(:error), "success should not carry :error"
  end

  def test_cancel_returns_success_with_reason
    result = RpmsRpc::Eprescribing.cancel("TX001", reason: "patient request")

    assert_equal true, result[:success]
  end

  def test_cancel_sends_bare_id_when_reason_blank
    RpmsRpc::Eprescribing.cancel("TX001")
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "PSO CANCEL RX" }
    refute_nil call
    assert_equal "TX001", call[:params].first
  end

  def test_cancel_sends_caret_composite_when_reason_present
    RpmsRpc::Eprescribing.cancel("TX001", reason: "patient request")
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "PSO CANCEL RX" }
    refute_nil call
    assert_equal "TX001^patient request", call[:params].first
  end

  def test_cancel_returns_failure_with_error_message
    result = RpmsRpc::Eprescribing.cancel("TX-NOPE")

    assert_equal false, result[:success]
    assert_equal "Not found", result[:error]
  end

  def test_cancel_returns_failure_for_blank_transmission_id
    nil_result   = RpmsRpc::Eprescribing.cancel(nil)
    empty_result = RpmsRpc::Eprescribing.cancel("", reason: "x")

    assert_equal false, nil_result[:success]
    assert_equal false, empty_result[:success]
    refute_nil nil_result[:error]
  end

  def test_cancel_rejects_whitespace_only_transmission_id
    result = RpmsRpc::Eprescribing.cancel("   ", reason: "patient request")

    assert_equal false, result[:success]
    refute_nil result[:error]
    refute RpmsRpc.client.received_calls.any? { |c| c[:rpc] == "PSO CANCEL RX" },
      "PSO CANCEL RX should not fire when transmission_id is whitespace-only"
  end

  def test_cancel_sends_bare_id_when_reason_is_whitespace_only
    RpmsRpc::Eprescribing.cancel("TX001", reason: "   ")

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "PSO CANCEL RX" }
    refute_nil call
    assert_equal "TX001", call[:params].first,
      "whitespace-only reason should be treated as no reason, sending bare id"
  end

  # === build_rx_param (public for observability) ===========================

  def test_build_rx_param_joins_attrs_in_pso_new_rx_order
    assert_equal RX_COMPOSITE, RpmsRpc::Eprescribing.build_rx_param(RX_ATTRS)
  end
end
