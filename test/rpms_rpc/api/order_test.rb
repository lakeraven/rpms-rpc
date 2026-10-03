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

  # === unsigned_for_patient (ORWOR UNSIGN) ===
  #
  # UNSIGN(LST,ORVP,HAVE) (ORWOR.m:114): the patient is ORVP, made into a
  # variable pointer at ORWOR.m:117; the user is the session DUZ
  # (ORWOR.m:116,126). Each row is IFN_";"_ACT and nothing else
  # (ORWOR.m:127).

  def test_unsigned_for_patient_sends_dfn_as_orvp
    RpmsRpc.mock! { |m| m.seed_raw_lines(:orders_unsigned, DFN, []) }

    RpmsRpc::Order.unsigned_for_patient(DFN)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWOR UNSIGN" }
    refute_nil call
    assert_equal [ DFN ], call[:params]
  end

  def test_unsigned_for_patient_parses_ifn_semicolon_action_rows
    RpmsRpc.mock! { |m| m.seed_raw_lines(:orders_unsigned, DFN, [ "1001;1", "1002;3" ]) }

    rows = RpmsRpc::Order.unsigned_for_patient(DFN)
    assert_equal [
      { order_id: "1001;1", ien: 1001, action_ien: 1 },
      { order_id: "1002;3", ien: 1002, action_ien: 3 }
    ], rows
  end

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

  AGET_REPLY = [
    "2^2^0",
    "2001;1^7^3261001.0915^^",
    "2002;2^12^3260930.1400^41^ADMIT TO MEDICINE"
  ].freeze

  def test_list_sends_dfn_filter_groups
    RpmsRpc.mock! { |m| m.seed_raw_lines(:orders_list, DFN, AGET_REPLY) }

    RpmsRpc::Order.list(DFN)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWORR AGET" }
    assert_equal [ DFN, "2", "1" ], call[:params]
  end

  def test_list_sends_display_group
    RpmsRpc.mock! { |m| m.seed_raw_lines(:orders_list, DFN, []) }

    RpmsRpc::Order.list(DFN, filter: :all, display_group: 5)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWORR AGET" }
    assert_equal [ DFN, "1", "5" ], call[:params]
  end

  def test_list_maps_each_filter_to_its_orchang2_id
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

    expected.each do |filter, id|
      RpmsRpc.mock! { |m| m.seed_raw_lines(:orders_list, DFN, []) }
      RpmsRpc::Order.list(DFN, filter: filter)
      call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWORR AGET" }
      assert_equal id, call[:params][1], "filter #{filter} should send #{id}"
    end
  end

  def test_list_parses_aget_rows_and_drops_the_header
    RpmsRpc.mock! { |m| m.seed_raw_lines(:orders_list, DFN, AGET_REPLY) }

    rows = RpmsRpc::Order.list(DFN)
    assert_equal 2, rows.length, "the .1 header TOT^TXTVW^ORYD is not an order"

    first, second = rows
    assert_equal "2001;1", first[:order_id]
    assert_equal 2001, first[:ien]
    assert_equal 7, first[:display_group_ien]
    assert_equal Time.new(2026, 10, 1, 9, 15), first[:action_datetime]
    assert_nil first[:event_ien]
    assert_nil first[:event_name]

    assert_equal 41, second[:event_ien]
    assert_equal "ADMIT TO MEDICINE", second[:event_name]
  end

  def test_list_header_only_reply_is_empty
    RpmsRpc.mock! { |m| m.seed_raw_lines(:orders_list, DFN, [ "0^2^0" ]) }
    assert_equal [], RpmsRpc::Order.list(DFN)
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

  def test_result_history_sends_dfn_orid_id
    RpmsRpc.mock! { |m| m.seed_text(:order_result_history, DFN, "x") }

    RpmsRpc::Order.result_history(DFN, "5001")
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWOR RESULT HISTORY" }
    refute_nil call
    assert_equal [ DFN, "5001", "5001" ], call[:params]
  end

  def test_result_history_returns_the_display_report
    report = "Previous 5 sets of related results within 5 years... \n" \
             " 10/01/2026 09:15  GLUCOSE      102  H  mg/dL  70-99"
    RpmsRpc.mock! { |m| m.seed_text(:order_result_history, DFN, report) }

    assert_equal report, RpmsRpc::Order.result_history(DFN, "5001")
  end

  def test_result_history_returns_nil_for_invalid_or_empty
    assert_nil RpmsRpc::Order.result_history(DFN, nil)
    assert_nil RpmsRpc::Order.result_history(nil, "5001")
    assert_nil RpmsRpc::Order.result_history("0", "5001")

    RpmsRpc.mock! { |m| m.seed_text(:order_result_history, DFN, "x") }
    assert_nil RpmsRpc::Order.result_history("9999", "5001")
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

  def test_expired_search_start_sends_no_params
    RpmsRpc.mock! { |m| m.seed_raw_lines(:order_expired, "", [ "3260930.1430" ]) }

    RpmsRpc::Order.expired_search_start
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWOR EXPIRED" }
    assert_equal [], call[:params]
  end

  def test_expired_search_start_returns_the_fileman_datetime
    RpmsRpc.mock! { |m| m.seed_raw_lines(:order_expired, "", [ "3260930.1430" ]) }
    assert_equal Time.new(2026, 9, 30, 14, 30), RpmsRpc::Order.expired_search_start
  end

  def test_expired_search_start_nil_when_no_answer
    RpmsRpc.mock!
    assert_nil RpmsRpc::Order.expired_search_start
  end

  def test_expired_predicate_is_gone
    refute_respond_to RpmsRpc::Order, :expired?
  end

  # === sheets_for_patient (ORWOR SHEETS) ===
  #
  # SHEETS(LST,ORVP) (ORWOR.m:91) writes "TYPE;ID^label" rows: C;O current
  # view, A;<ts>/A;-1 admit, T;<ts>/T;-1 transfer, D;0 discharge
  # (ORWOR.m:97-105).

  SHEETS_REPLY = [
    "C;O^Current View",
    "A;12^Admit to MEDICINE",
    "A;-1^Admit...",
    "D;0^Discharge"
  ].freeze

  def test_sheets_for_patient_sends_dfn_as_orvp
    RpmsRpc.mock! { |m| m.seed_raw_lines(:order_sheets, DFN, SHEETS_REPLY) }
    RpmsRpc::Order.sheets_for_patient(DFN)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWOR SHEETS" }
    assert_equal [ DFN ], call[:params]
  end

  def test_sheets_for_patient_keeps_the_composite_id
    RpmsRpc.mock! { |m| m.seed_raw_lines(:order_sheets, DFN, SHEETS_REPLY) }

    rows = RpmsRpc::Order.sheets_for_patient(DFN)
    assert_equal [
      { sheet_id: "C;O",  event_type: "C", event_ref: "O",  label: "Current View" },
      { sheet_id: "A;12", event_type: "A", event_ref: "12", label: "Admit to MEDICINE" },
      { sheet_id: "A;-1", event_type: "A", event_ref: "-1", label: "Admit..." },
      { sheet_id: "D;0",  event_type: "D", event_ref: "0",  label: "Discharge" }
    ], rows
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
