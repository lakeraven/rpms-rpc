# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/order"
require_relative "../captured_replies"

# What list, unsigned_for_patient, expired_search_start, sheets_for_patient
# and result_history send and how they read a reply is proven live in
# test/live/order_live_test.rb (#220). For those, these cases cover only what
# the gem decides without the server: argument guards and removed methods.
# result, action_text and all_sheets replay test/fixtures/captured_replies/order-reads.yml,
# captured live as the physician PROFILE,MD on the seeded order (order 1,
# DFN 4), through CiaClient's own reply grammar (#823, #620).
class OrderTest < Minitest::Test
  DFN = "8791"
  SLUG = "order-reads"

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow)
    client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(SLUG, flow))
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

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

  # RESULT(REF,DFN,ORID,ID) (ORWOR.m:29): the patient comes first and the
  # order IEN fills ORID and ID (#259). ORDERS^ORCXPND1 reads the order by
  # its IEN, so the reply is the order's text and results for any DFN.
  def test_result_is_the_orders_text_and_results_for_any_patient
    %w[result_seed result_other_patient].zip([ 4, 3 ]).each do |flow, dfn|
      client = replay(flow)

      text = RpmsRpc::Order.result(dfn, 1)
      assert_includes text, ">> Ambulate in hallway twice daily as tolerated.", flow
      assert_includes text, "There are no results to report.", flow
      assert_equal CapturedReplies.flow_calls(SLUG, flow), sent(client)
    end
  end

  def test_result_with_an_invalid_id_reaches_no_wire
    client = replay("result_seed")

    assert_nil RpmsRpc::Order.result(DFN, nil)
    assert_nil RpmsRpc::Order.result(DFN, "0")
    assert_nil RpmsRpc::Order.result(nil, "5001")
    assert_nil RpmsRpc::Order.result("0", "5001")
    assert_empty sent(client)
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

  # === action_text (ORWOR ACTION TEXT) ===
  #
  # ACTXT(ORY,ORIFN) (ORWOR.m:139) takes one actual, IFN;ACT, and lists the
  # actions after ACT; IFN;0 lists them all (ORWOR.m:142-144). A second
  # actual died in M with ACTLSTTOOLONG (#823). The build registers the RPC
  # as ARRAY while ACTXT answers a global name, so the broker sends no lines,
  # for an order on file as for one that is not.

  def test_action_text_sends_ifn_zero_as_the_one_actual
    %w[action_text_seed action_text_unknown].zip([ 1, 999_999 ]).each do |flow, ien|
      client = replay(flow)

      assert_nil RpmsRpc::Order.action_text(ien), flow
      assert_equal [ [ "ORWOR ACTION TEXT", [ "#{ien};0" ] ] ], sent(client), flow
      assert_equal CapturedReplies.flow_calls(SLUG, flow), sent(client)
    end
  end

  def test_action_text_with_an_invalid_ien_reaches_no_wire
    client = replay("action_text_seed")

    [ nil, "", 0, -1, "abc", "1;1" ].each { |ien| assert_nil RpmsRpc::Order.action_text(ien), ien.inspect }
    assert_empty sent(client)
  end

  def test_action_text_takes_only_the_order
    assert_equal [ [ :req, :order_ien ] ], RpmsRpc::Order.method(:action_text).parameters
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

  # === all_sheets (ORWOR TSALL) ===
  #
  # TSALL(LST) (ORWOR.m:44-46) lists the site's active treating specialties,
  # file 45.7, as IEN^NAME: not order sheets.

  def test_all_sheets_lists_the_sites_treating_specialties
    client = replay("all_sheets")

    expected = [
      { ien: 4, name: "GENERAL SURGERY" }, { ien: 6, name: "INTERNAL MEDICINE" }, { ien: 7, name: "NEWBORN" },
      { ien: 11, name: "PEDIATRICS" }, { ien: 17, name: "FAMILY PRACTICE" }
    ]
    assert_equal expected, RpmsRpc::Order.all_sheets
    assert_equal CapturedReplies.flow_calls(SLUG, "all_sheets"), sent(client)
  end
end
