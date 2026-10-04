# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/order"

# What list, unsigned_for_patient, expired_search_start, sheets_for_patient
# and result_history send and how they read a reply is proven live in
# test/live/order_live_test.rb (#220). For those, these cases cover only what
# the gem decides without the server: argument guards and removed methods.
class OrderTest < Minitest::Test
  DFN = "8791"

  def teardown
    RpmsRpc.reset!
  end

  # === unsigned_for_patient (ORWOR UNSIGN) ===
  #
  # UNSIGN(LST,ORVP,HAVE) (ORWOR.m:114): the patient is ORVP, made into a
  # variable pointer at ORWOR.m:117; the user is the session DUZ
  # (ORWOR.m:116,126). Each row is IFN_";"_ACT and nothing else
  # (ORWOR.m:127).

  def test_unsigned_for_patient_blank_returns_empty
    assert_equal [], RpmsRpc::Order.unsigned_for_patient(nil)
    assert_equal [], RpmsRpc::Order.unsigned_for_patient("0")
  end

  def test_unsigned_for_user_is_gone
    refute_respond_to RpmsRpc::Order, :unsigned_for_user
  end

  # === list (ORWORR AGET) ===
  #
  # AGET(REF,DFN,FILTER,GROUPS,DTFROM,DTTHRU,EVENT) (ORWORR.m:25). FILTER is
  # an ORDSTS^ORCHANG2 view id (ORCHANG2.m:37-63); GROUPS and FILTER default
  # to 1 and 2 (ORWORR.m:33). GET1^ORWORR1 writes rows
  # IFN;ACT^DGrp^ActTm^PtEvtID^EvtName (ORWORR1.m:11) under a .1 header
  # TOT^TXTVW^ORYD (ORWORR1.m:13), which sorts first.

  def test_filter_ids_are_the_orchang2_view_ids
    expected = {
      all: "1", active: "2", current: "23", discontinued: "3",
      discontinued_or_entered_in_error: "28", completed_or_expired: "4",
      expiring: "5", pending: "7", on_hold: "18", new: "19", unsigned: "11",
      unverified: "8", unverified_by_nursing: "9", unverified_by_clerk: "10",
      unverified_chart_review: "20", verbal: "13", verbal_unsigned: "14",
      flagged: "12", recent_activity: "6", delayed: "24",
      delayed_admission: "15", delayed_transfer: "17", delayed_discharge: "16",
      delayed_return_from_or: "25", delayed_manual_release: "26", lapsed: "22"
    }
    assert_equal expected, RpmsRpc::Order::FILTER_IDS
  end

  def test_list_raises_on_unknown_filter
    assert_raises(ArgumentError) { RpmsRpc::Order.list(DFN, filter: :nope) }
  end

  def test_list_blank_dfn_returns_empty
    assert_equal [], RpmsRpc::Order.list(nil)
    assert_equal [], RpmsRpc::Order.list("0")
  end

  # === result ===

  # RESULT(REF,DFN,ORID,ID) (ORWOR.m:29): the patient comes first, so the
  # mock keys the reply by DFN (#259).
  def test_result_returns_text_for_order
    RpmsRpc.mock! do |m|
      m.seed_text(:order_result, DFN,
        "GLUCOSE  102 mg/dL  (70-99)  H\nNOTE: fasting")
    end
    text = RpmsRpc::Order.result(DFN, "5001")
    assert_match(/GLUCOSE/, text)
    assert_match(/fasting/, text)
  end

  def test_result_returns_nil_for_invalid_or_unknown
    assert_nil RpmsRpc::Order.result(DFN, nil)
    assert_nil RpmsRpc::Order.result(DFN, "0")
    assert_nil RpmsRpc::Order.result(nil, "5001")
    assert_nil RpmsRpc::Order.result("0", "5001")

    RpmsRpc.mock! { |m| m.seed_text(:order_result, DFN, "x") }
    assert_nil RpmsRpc::Order.result("9999", "5001")
  end

  # === result_history (ORWOR RESULT HISTORY) ===
  #
  # RESHIST(REF,DFN,ORID,ID) (ORWOR.m:36): the same formals as RESULT;
  # ORDHIST^ORWOR2 reads ID as the file 100 IEN (ORWOR2.m:7) and writes a
  # display report into ^TMP("ORXPND",$J,n,0) (ORWOR.m:42, ORWOR2.m:14).

  def test_result_history_returns_nil_for_invalid_ids
    assert_nil RpmsRpc::Order.result_history(DFN, nil)
    assert_nil RpmsRpc::Order.result_history(nil, "5001")
    assert_nil RpmsRpc::Order.result_history("0", "5001")
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

  # === expired_search_start (ORWOR EXPIRED) ===
  #
  # EXPIRED(ORY) (ORWOR.m:147) takes no parameter and answers NOW less the
  # ORWOR EXPIRED ORDERS hours, as a FileMan date/time (ORWOR.m:149-150).

  def test_expired_predicate_is_gone
    refute_respond_to RpmsRpc::Order, :expired?
  end

  # === sheets_for_patient (ORWOR SHEETS) ===
  #
  # SHEETS(LST,ORVP) (ORWOR.m:91) writes "TYPE;ID^label" rows: C;O current
  # view, A;<ts>/A;-1 admit, T;<ts>/T;-1 transfer, D;0 discharge
  # (ORWOR.m:97-105).

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
