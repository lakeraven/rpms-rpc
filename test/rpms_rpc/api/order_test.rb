# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/order"

class OrderTest < Minitest::Test
  USER_DUZ = "301"
  DFN      = "8791"

  def teardown
    RpmsRpc.reset!
  end

  def test_unsigned_for_user_returns_unsigned_queue
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:orders_unsigned, USER_DUZ, [
        { ien: 1001, patient_dfn: 8791, patient_name: "TEST PATIENT A", order_text: "Lasix 20mg PO QD", status: "unsigned" },
        { ien: 1002, patient_dfn: 8792, patient_name: "TEST PATIENT B", order_text: "Metformin 500mg", status: "unsigned" }
      ])
    end

    rows = RpmsRpc::Order.unsigned_for_user(USER_DUZ)
    assert_equal 2, rows.length
    assert_equal 1001, rows.first[:ien]
  end

  def test_unsigned_for_user_dispatches_orwor_unsign
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:orders_unsigned, USER_DUZ, [])
    end

    RpmsRpc::Order.unsigned_for_user(USER_DUZ)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWOR UNSIGN" }
    refute_nil call
    assert_equal [ USER_DUZ ], call[:params]
  end

  def test_unsigned_for_user_blank_returns_empty
    assert_equal [], RpmsRpc::Order.unsigned_for_user(nil)
    assert_equal [], RpmsRpc::Order.unsigned_for_user("0")
  end

  def test_list_returns_orders_for_patient
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:orders_list, DFN, [
        { ien: 2001, order_text: "Labs: CBC", status: "active" }
      ])
    end

    rows = RpmsRpc::Order.list(DFN)
    assert_equal 1, rows.length
  end

  def test_list_passes_each_view_code_to_rpc
    expected = { default: "1", active: "2", expiring: "3", expired: "4", scheduled: "5" }
    expected.each do |view, code|
      RpmsRpc.mock! do |m|
        m.seed_keyed_collection(:orders_list, DFN, [])
      end
      RpmsRpc::Order.list(DFN, view: view)
      call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWORR AGET" }
      assert_equal code, call[:params][1], "view #{view} should map to #{code}"
    end
  end

  def test_list_passes_each_status_code_to_rpc
    expected = { all: "*", active: "A", pending: "P", complete: "C", expired: "E" }
    expected.each do |status, code|
      RpmsRpc.mock! do |m|
        m.seed_keyed_collection(:orders_list, DFN, [])
      end
      RpmsRpc::Order.list(DFN, status: status, view: :default)
      call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWORR AGET" }
      assert_equal code, call[:params][2], "status #{status} should map to #{code}"
    end
  end

  def test_list_raises_on_unknown_view
    assert_raises(ArgumentError) { RpmsRpc::Order.list(DFN, view: :nope) }
  end

  def test_list_raises_on_unknown_status
    assert_raises(ArgumentError) { RpmsRpc::Order.list(DFN, status: :nope) }
  end

  def test_list_blank_dfn_returns_empty
    assert_equal [], RpmsRpc::Order.list(nil)
    assert_equal [], RpmsRpc::Order.list("0")
  end

  # === result ===

  def test_result_returns_text_for_order
    RpmsRpc.mock! do |m|
      m.seed_text(:order_result, "5001",
        "GLUCOSE  102 mg/dL  (70-99)  H\nNOTE: fasting")
    end
    text = RpmsRpc::Order.result("5001")
    assert_match(/GLUCOSE/, text)
    assert_match(/fasting/, text)
  end

  def test_result_returns_nil_for_invalid_or_unknown
    assert_nil RpmsRpc::Order.result(nil)
    assert_nil RpmsRpc::Order.result("0")

    RpmsRpc.mock! { |m| m.seed_text(:order_result, "5001", "x") }
    assert_nil RpmsRpc::Order.result("9999")
  end

  # === result_history ===

  def test_result_history_returns_rows
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:order_result_history, "5001", [
        { value: "102", units: "mg/dL", abnormal_flag: "H", reference_range: "70-99", status: "final" },
        { value: "94",  units: "mg/dL", abnormal_flag: "",  reference_range: "70-99", status: "final" }
      ])
    end
    rows = RpmsRpc::Order.result_history("5001")
    assert_equal 2, rows.length
    assert_equal "102", rows.first[:value]
    assert_equal "H",   rows.first[:abnormal_flag]
  end

  def test_result_history_dispatches_rpc
    RpmsRpc.mock! { |m| m.seed_keyed_collection(:order_result_history, "5001", []) }
    RpmsRpc::Order.result_history("5001")
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWOR RESULT HISTORY" }
    refute_nil call
    assert_equal [ "5001" ], call[:params]
  end

  def test_result_history_returns_empty_for_invalid
    assert_equal [], RpmsRpc::Order.result_history(nil)
    assert_equal [], RpmsRpc::Order.result_history("0")
  end

  # === action_text ===

  def test_action_text_returns_text
    RpmsRpc.mock! do |m|
      m.seed_text(:order_action_text, "5001",
        "Releasing this order will notify pharmacy.")
    end
    text = RpmsRpc::Order.action_text("5001", "RL")
    assert_match(/Releasing/, text)
  end

  def test_action_text_dispatches_with_action_code
    RpmsRpc.mock! { |m| m.seed_text(:order_action_text, "5001", "x") }
    RpmsRpc::Order.action_text("5001", "RL")
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWOR ACTION TEXT" }
    refute_nil call
    assert_equal [ "5001", "RL" ], call[:params]
  end

  def test_action_text_returns_nil_for_blank_inputs
    assert_nil RpmsRpc::Order.action_text(nil, "RL")
    assert_nil RpmsRpc::Order.action_text("5001", nil)
    assert_nil RpmsRpc::Order.action_text("5001", "")
  end

  # === expired? ===

  def test_expired_returns_true_when_broker_says_so
    RpmsRpc.mock! { |m| m.seed_scalar(:order_expired, "5001", true) }
    assert_equal true, RpmsRpc::Order.expired?("5001")
  end

  def test_expired_returns_false_when_broker_says_so
    RpmsRpc.mock! { |m| m.seed_scalar(:order_expired, "5001", false) }
    assert_equal false, RpmsRpc::Order.expired?("5001")
  end

  def test_expired_returns_nil_for_invalid_input
    assert_nil RpmsRpc::Order.expired?(nil)
    assert_nil RpmsRpc::Order.expired?("0")
  end

  # === sheets_for_patient ===

  def test_sheets_for_patient_returns_rows
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:order_sheets, DFN, [
        { ien: 1, name: "Current",      sheet_type: "A", status: "active" },
        { ien: 2, name: "Delay Release", sheet_type: "D", status: "delayed" }
      ])
    end
    rows = RpmsRpc::Order.sheets_for_patient(DFN)
    assert_equal 2, rows.length
    assert_equal "Current", rows.first[:name]
  end

  def test_sheets_for_patient_returns_empty_for_invalid
    assert_equal [], RpmsRpc::Order.sheets_for_patient(nil)
    assert_equal [], RpmsRpc::Order.sheets_for_patient("0")
  end

  # === all_sheets ===

  def test_all_sheets_returns_site_catalog
    RpmsRpc.mock! do |m|
      m.seed_collection(:order_sheets_all, [
        { ien: 1, name: "Inpatient Meds" },
        { ien: 2, name: "Outpatient Meds" }
      ])
    end
    rows = RpmsRpc::Order.all_sheets
    assert_equal 2, rows.length
    assert_equal "Inpatient Meds", rows.first[:name]
  end
end
