# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/order"
require "rpms_rpc/api/ddr_fileman"

# RpmsRpc::Order's order reads against the pinned build (#220): list (ORWORR
# AGET), unsigned_for_patient (ORWOR UNSIGN), expired_search_start (ORWOR
# EXPIRED), sheets_for_patient (ORWOR SHEETS) and result_history (ORWOR
# RESULT HISTORY). They replace the fabricated-reply cases of order_test.rb.
#
# What the build holds decides what a reply can show: the ORDER file (#100)
# is empty on the 0930 build, so the specs prove what holds for any patient
# (AGET's header, the sheets every patient has, the EXPIRED arithmetic) and
# check every row against file 100. The row-layout specs that need an order
# on file wait on #391 (rpms-ops#723).
#
# Every RPC here is in CIAV VUECENTRIC, the option sign-on binds, for PROV123
# and the programmer alike. These specs read only; they file nothing.
class OrderLiveTest < LiveSpec::Test
  DEMO_DFNS = %w[3 4 990001 990027].freeze

  # AGET's MULT views (ORWORR.m: S MULT=...): the header's TXTVW is 0 for
  # them, 2 for FILTER 2 and 1 for any other view (ORWORR1.m:12).
  MULT_FILTER_IDS = %w[1 6 8 9 10 11 13 14 20 22].freeze

  # -- list (ORWORR AGET) ------------------------------------------------------

  # GET1^ORWORR1 writes the header TOT^TXTVW^ORYD at .1 (ORWORR1.m:13): AGET
  # read the FILTER the gem sent when TXTVW is the one that view gives, and
  # list returns TOT rows, the header not among them.
  def test_list_sends_each_filter_id_as_agets_view_and_returns_tot_rows
    dfn = DEMO_DFNS.first
    RpmsRpc::Order::FILTER_IDS.each do |filter, id|
      tot, txtvw, = aget_header(dfn, id)
      expected_view = if MULT_FILTER_IDS.include?(id) then 0 elsif id == "2" then 2 else 1 end
      assert_equal expected_view, txtvw, "filter #{filter} (#{id}): AGET's TXTVW says it read a different view"

      rows = RpmsRpc::Order.list(dfn, filter: filter)
      assert_equal tot, rows.length, "filter #{filter}: AGET counted #{tot} orders, list returned #{rows.length}"
    end
  end

  def test_list_rows_are_orders_on_file_for_the_patient
    DEMO_DFNS.each do |dfn|
      rows = RpmsRpc::Order.list(dfn, filter: :all)
      assert_kind_of Array, rows
      on_file = order_iens_for(dfn)
      rows.each { |row| assert_includes on_file, row[:ien], "DFN #{dfn}: AGET listed order #{row[:ien]}, which file 100 does not hold for the patient" }
    end
  end

  def test_list_row_layout
    dfn, = first_order
    skip_tracked("#391", "no order in file 100 on the pinned build (rpms-ops#723)") if dfn.nil?

    row = RpmsRpc::Order.list(dfn, filter: :all).first
    refute_nil row, "file 100 holds an order for DFN #{dfn}, and AGET listed none"
    assert_match(/\A\d+;\d+\z/, row[:order_id])
    assert_equal row[:order_id].split(";").first.to_i, row[:ien]
    assert_kind_of Integer, row[:display_group_ien]
  end

  # -- unsigned_for_patient (ORWOR UNSIGN) -------------------------------------

  def test_unsigned_rows_are_actions_of_orders_on_file
    DEMO_DFNS.each do |dfn|
      rows = RpmsRpc::Order.unsigned_for_patient(dfn)
      assert_kind_of Array, rows
      on_file = order_iens_for(dfn)
      rows.each do |row|
        assert_equal "#{row[:ien]};#{row[:action_ien]}", row[:order_id], "DFN #{dfn}: #{row.inspect}"
        assert_includes on_file, row[:ien], "DFN #{dfn}: UNSIGN named order #{row[:ien]}, which file 100 does not hold for the patient"
      end
    end
  end

  def test_unsigned_row_layout
    dfn, = first_order
    skip_tracked("#391", "no order in file 100 on the pinned build (rpms-ops#723)") if dfn.nil?

    rows = RpmsRpc::Order.unsigned_for_patient(dfn)
    skip_tracked("#391", "no unsigned order on the pinned build for #{persona} (rpms-ops#723)") if rows.empty?
    assert(rows.all? { |r| r[:ien].positive? && r[:action_ien].positive? }, rows.inspect)
  end

  # -- expired_search_start (ORWOR EXPIRED) ------------------------------------

  # EXPIRED(ORY) answers NOW less the ORWOR EXPIRED ORDERS hours
  # (ORWOR.m:147-150): before the server's NOW, by a whole number of hours.
  def test_expired_search_start_is_now_less_whole_hours
    start = RpmsRpc::Order.expired_search_start
    now = server_now
    assert_kind_of Time, start
    assert_operator start, :<=, now, "ORWOR EXPIRED answered a time after the server's NOW"

    off = (now - start) % 3600
    assert(off <= 5 || off >= 3595, "NOW - #{start} is not a whole number of hours (#{off.round}s over)")
  end

  # -- sheets_for_patient (ORWOR SHEETS) ---------------------------------------

  # Every patient has the current view and the admit event (ORWOR.m:97-100);
  # transfer and discharge come only for a patient on a ward (ORWOR.m:104-106).
  def test_sheets_start_with_the_current_view_and_offer_admission
    DEMO_DFNS.each do |dfn|
      rows = RpmsRpc::Order.sheets_for_patient(dfn)
      assert_equal({ sheet_id: "C;O", event_type: "C", event_ref: "O", label: "Current View" }, rows.first, "DFN #{dfn}")
      assert_includes rows, { sheet_id: "A;-1", event_type: "A", event_ref: "-1", label: "Admit..." }, "DFN #{dfn}"
      rows.each do |row|
        assert_equal "#{row[:event_type]};#{row[:event_ref]}", row[:sheet_id], "DFN #{dfn}: #{row.inspect}"
        refute_empty row[:label].to_s, "DFN #{dfn}: #{row.inspect}"
      end
    end
  end

  # -- result_history (ORWOR RESULT HISTORY) -----------------------------------

  # ORDHIST^ORWOR2 writes a display report even when there is nothing to show
  # (ORWOR2.m:9-13), so an order with no results answers that line, not nil.
  def test_result_history_for_an_order_without_results_says_so
    order_ien = (order_iens.max || 0) + 1
    text = RpmsRpc::Order.result_history(DEMO_DFNS.first, order_ien)
    assert_kind_of String, text
    assert_includes text, "There are no results to report"
  end

  def test_result_history_for_an_order_on_file
    dfn, order_ien = first_order
    skip_tracked("#391", "no order in file 100 on the pinned build (rpms-ops#723)") if dfn.nil?

    text = RpmsRpc::Order.result_history(dfn, order_ien)
    assert_kind_of String, text
    refute_empty text.strip
  end

  private

  # [TOT, TXTVW, ORYD] from AGET's .1 header line.
  def aget_header(dfn, filter_id)
    reply = client.call_rpc("ORWORR AGET", dfn, filter_id, RpmsRpc::Order::DEFAULT_DISPLAY_GROUP.to_s)
    header = Array(reply).first.to_s
    assert_match(/\A\d+\^\d\^[\d.]+\z/, header, "AGET's first line is not TOT^TXTVW^ORYD")
    tot, txtvw, oryd = header.split("^")
    [ tot.to_i, txtvw.to_i, oryd ]
  end

  def server_now
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    RpmsRpc::FilemanDateParser.parse_datetime(value) || flunk("ORWU DT NOW answered #{value.inspect}")
  end

  # { order IEN => patient DFN } for every order in file 100 (field .02,
  # OBJECT OF ORDER, is a variable pointer "DFN;DPT(").
  def orders
    @orders ||= begin
      listed = RpmsRpc::DdrFileman.lister(file: "100", fields: "@;.02", flags: "IP")
      flunk "DDR LISTER on ORDER (100) gave no reply" if listed.nil?
      flunk "DDR LISTER on ORDER (100) answered an error" if listed[:error]

      listed[:entries].to_h { |e| [ e[:ien].to_i, e[:pieces].first.to_s ] }
    end
  end

  def order_iens = orders.keys

  def order_iens_for(dfn)
    orders.select { |_, object| object == "#{dfn};DPT(" }.keys
  end

  # [DFN, order IEN] of the first order on a patient, or nil.
  def first_order
    ien, object = orders.find { |_, o| o.end_with?(";DPT(") }
    ien && [ object.split(";").first, ien ]
  end
end
