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
end
