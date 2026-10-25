# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "thread"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/order"

# rpms-rpc#454: Order.check over ORWDXC ACCEPT (CHK2LST reply, ORWDXC.m:138-147).
#
# Issue text names (dfn, order_dialog, responses); the broker formal list is
# ACCEPT(LST,DFN,FID,STRT,ORL,OIL,ORIFN) (ORWDXC.m:45) — seven client actuals
# after LST (stock VistA adds an unread 8th ORREN). FID is the filler namespace
# from FILLID^ORWDXC (ORWDXC.m:7-16), not the dialog IEN. OIL(n) is
# OIptr^PKG^PkgInfo (ORWDXC.m:46).
class OrderCheckTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  DFN = "8791"
  FILLER_ID = "OR"
  LOCATION = "349"
  ITEM_ONE = "1001^PS^2001"
  ITEM_TWO = "1002^LR^Synthetic lab orderable"

  DFN_B = "8792"
  FDB_INCOMPLETE_BANNER =
    "NEW^25^2^||66000,123,NEW&These checks could not be completed for this patient:"
  ORDINARY_LOW_CHECK = "NEW^502^3^Low only"
  MALFORMED_CHK2LST_ROW = "NEW^17"
  REMOTE_CHECKING_UNAVAILABLE_ROW =
    "NEW^99^2^Remote Order Checking not available - checks done on local data only"

  BARE_CR_LOW_CHECK = "NEW^5^3^Synthetic low check"
  BARE_CR_HIGH_CHECK = "NEW^9^1^Synthetic HIGH interaction"
  BARE_CR_TWO_ROW_REPLY = "#{BARE_CR_LOW_CHECK}\r#{BARE_CR_HIGH_CHECK}"

  CONCURRENT_JOIN_LIMIT = 5
  WIRE_LOCK_DEADLOCK_JOIN_LIMIT = 3

  def teardown
    RpmsRpc.reset!
  end

  # --- RPC frame (ORWDXC ACCEPT) ------------------------------------------------

  def test_check_dispatches_orwdxc_accept_with_formal_parameter_order_and_oil_list
    RpmsRpc.mock!
    items = [ ITEM_ONE, ITEM_TWO ]

    RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: items,
                         start: "NEXT", order_id: "5001;1")

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWDXC ACCEPT" }
    refute_nil call, "ORWDXC ACCEPT was not called"
    assert_equal DFN, call[:params][0]
    assert_equal FILLER_ID, call[:params][1]
    assert_equal "NEXT", call[:params][2]
    assert_equal LOCATION, call[:params][3]
    assert_equal "5001;1", call[:params][5]
    assert_oil_list_param(call[:params][4], [ ITEM_ONE, ITEM_TWO ])
  end

  def test_check_joins_hash_items_into_oil_caret_rows
    RpmsRpc.mock!
    items = [
      { orderable_item: "2001", package: "PS", package_info: "2001" },
      { orderable_item: "2002", package: "PSIV", package_info: "B;100" }
    ]

    RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: items)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWDXC ACCEPT" }
    assert_oil_list_param(call[:params][4], [ "2001^PS^2001", "2002^PSIV^B;100" ])
  end

  def test_check_sends_empty_string_for_new_order_orifn
    RpmsRpc.mock!
    RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWDXC ACCEPT" }
    assert_equal "", call[:params][5]
  end

  # --- CHK2LST parsing (ORWDXC.m:138-147, CDL per ORCHECK.m:85-90) --------------

  def test_check_parses_high_moderate_and_low_rows_and_requires_override_for_high
    with_orwdxc_accept_wire([
      "NEW^401^1^High severity synthetic alert",
      "123;1^402^2^Moderate alert on existing order",
      "NEW^403^3^Low informational note"
    ])

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    assert result.available?
    assert result.override_required?
    assert_nil result.unavailable_reason

    by_severity = result.checks.group_by(&:severity)
    assert_equal 1, by_severity[:high].length
    assert_equal 1, by_severity[:moderate].length
    assert_equal 1, by_severity[:low].length

    high = by_severity[:high].first
    assert_equal "NEW", high.order_id
    assert_equal "401", high.check_ien
    assert_equal "High severity synthetic alert", high.text
    assert high.override_required?

    moderate = by_severity[:moderate].first
    assert_equal "123;1", moderate.order_id
    assert_equal "402", moderate.check_ien
    refute moderate.override_required?
  end

  def test_check_moderate_and_low_only_does_not_require_override
    with_orwdxc_accept_wire([
      "NEW^501^2^Moderate only",
      "NEW^502^3^Low only"
    ])

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    assert result.available?
    refute result.override_required?
    assert_equal %i[low moderate], result.checks.map(&:severity).sort
  end

  def test_check_only_ordinary_checks_is_complete
    with_orwdxc_accept_wire([
      "NEW^501^2^Moderate only",
      "NEW^502^3^Low only"
    ])

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    assert result.available?
    assert result.complete?
    refute result.override_required?
  end

  def test_check_fdb_down_incomplete_banner_is_incomplete_and_requires_override
    with_orwdxc_accept_wire([
      "NEW^25^2^||66000,123,NEW&These checks could not be completed for this patient:"
    ])

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    assert result.available?
    refute result.complete?
    assert result.override_required?

    check = result.checks.first
    assert check.incomplete?
    assert check.override_required?
    assert_equal "These checks could not be completed for this patient:", check.text
    assert_equal "66000,123,NEW", check.extended_text_key
  end

  def test_check_incomplete_banner_matched_by_text_not_check_ien_or_cdl
    with_orwdxc_accept_wire([
      "NEW^777^1^||99001,42,NEW&These checks could not be completed for this patient:"
    ])

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    check = result.checks.first
    assert check.incomplete?
    assert check.override_required?
    refute result.complete?
  end

  def test_check_remote_order_checking_unavailable_row_is_incomplete_and_not_complete
    with_orwdxc_accept_wire([ REMOTE_CHECKING_UNAVAILABLE_ROW ])

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    assert result.available?
    refute result.complete?
    assert result.override_required?

    check = result.checks.find { |c| c.check_ien == "99" } ||
            result.checks.find { |c| c.text.start_with?("Remote Order Checking not available") }
    refute_nil check
    assert check.incomplete?
    assert check.override_required?
  end

  def test_check_opos_session_memo_fdb_incomplete_banner_omitted_later_still_incomplete
    with_orwdxc_accept_sequence([
      [ FDB_INCOMPLETE_BANNER, ORDINARY_LOW_CHECK ],
      [ ORDINARY_LOW_CHECK ],
      [ ORDINARY_LOW_CHECK ]
    ])

    first = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    assert first.available?
    refute first.complete?

    second = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    assert second.available?
    refute second.complete?
    assert second.override_required?
    session_reason = (second.incomplete_reason || second.session_incomplete_reason).to_s
    assert_match(/incomplete/i, session_reason)
    assert_match(/session/i, session_reason)

    third = RpmsRpc::Order.check(DFN_B, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    assert third.available?
    assert third.complete?

    with_orwdxc_accept_wire([ ORDINARY_LOW_CHECK ])
    fresh = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    assert fresh.available?
    assert fresh.complete?
  end

  def test_check_opos_session_memo_remote_checking_row_omitted_later_still_incomplete
    with_orwdxc_accept_sequence([
      [ REMOTE_CHECKING_UNAVAILABLE_ROW, ORDINARY_LOW_CHECK ],
      [ ORDINARY_LOW_CHECK ],
      [ ORDINARY_LOW_CHECK ]
    ])

    first = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    refute first.complete?

    second = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    refute second.complete?
    assert second.override_required?
    session_reason = (second.incomplete_reason || second.session_incomplete_reason).to_s
    assert_match(/incomplete/i, session_reason)
    assert_match(/session/i, session_reason)

    third = RpmsRpc::Order.check(DFN_B, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    assert third.complete?

    with_orwdxc_accept_wire([ ORDINARY_LOW_CHECK ])
    fresh = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    assert fresh.complete?
  end

  def test_check_opos_session_memo_concurrent_same_dfn_blocks_until_first_finishes
    replies = [
      [ FDB_INCOMPLETE_BANNER, ORDINARY_LOW_CHECK ],
      [ ORDINARY_LOW_CHECK ]
    ]
    sync = Mutex.new
    cv = ConditionVariable.new
    call_count = 0
    a_inside_rpc = false
    b_entered_rpc = false

    client = RpmsRpc::MockClient.new
    %i[call_rpc call_rpc_lines call_rpc_global_array].each do |meth|
      client.define_singleton_method(meth) do |rpc_name, *params|
        received_calls << { rpc: rpc_name, params: params, context: current_context }
        raise "unexpected RPC #{rpc_name.inspect}" unless rpc_name == "ORWDXC ACCEPT"

        n = sync.synchronize do
          call_count += 1
          call_count
        end
        wire = replies.fetch(n - 1)

        if n == 1
          sync.synchronize do
            a_inside_rpc = true
            cv.broadcast
          end
          sleep 0.15
        else
          sync.synchronize { b_entered_rpc = true }
        end
        wire
      end
    end
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }

    result_a = nil
    result_b = nil
    thread_a = Thread.new do
      result_a = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    end

    sync.synchronize do
      cv.wait(sync, CONCURRENT_JOIN_LIMIT) until a_inside_rpc
    end

    thread_b = Thread.new do
      result_b = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    end
    sleep 0.05
    refute b_entered_rpc, "second ACCEPT must not run while the first is still inside call_rpc"

    assert thread_a.join(CONCURRENT_JOIN_LIMIT), "thread A did not finish"
    assert thread_b.join(CONCURRENT_JOIN_LIMIT), "thread B did not finish"

    refute result_a.complete?
    refute result_b.complete?
    assert result_b.override_required?
    session_reason = result_b.incomplete_reason.to_s
    assert_match(/incomplete/i, session_reason)
    assert_match(/session/i, session_reason)
  end

  # ACCEPT runs OPOS before CHK2LST (ORWDXC.m:53-55). An M-side fault after OPOS
  # still leaves the banner suppressed on the next ACCEPT for that DFN; the client
  # must remember the DFN when call_rpc raises, not only when parse_accept_reply runs.
  def test_check_rpc_m_error_after_accept_opos_still_memoizes_dfn
    assert_accept_fault_after_opos_still_memoizes_dfn(RpmsRpc::Client::RpcMError, "synthetic M error after OPOS")
  end

  def test_check_rpc_error_after_accept_opos_still_memoizes_dfn
    assert_accept_fault_after_opos_still_memoizes_dfn(RpmsRpc::Client::RpcError, "synthetic broker error after OPOS")
  end

  def test_check_parse_error_after_accept_opos_still_memoizes_dfn
    assert_accept_fault_after_opos_still_memoizes_dfn(RpmsRpc::Client::ParseError, "synthetic parse error on ACCEPT reply")
  end

  def test_check_timeout_error_during_accept_does_not_memoize_dfn
    message = "synthetic RPC timeout after OPOS"
    with_orwdxc_accept_raise_then_sequence(RpmsRpc::Client::TimeoutError, message, [
      [ ORDINARY_LOW_CHECK ],
      [ ORDINARY_LOW_CHECK ]
    ])

    error = assert_raises(RpmsRpc::Client::TimeoutError) do
      RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    end
    assert_equal message, error.message

    second = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    assert second.available?
    assert second.complete?
    refute second.override_required?

    third = RpmsRpc::Order.check(DFN_B, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    assert third.available?
    assert third.complete?
  end

  # Production Client#call_rpc runs inside wire_operation → synchronize_wire.
  # Order.check must serialize on that same reentrant lock (via RpmsRpc.synchronize_wire),
  # not a separate per-client Mutex held across call_rpc — opposite lock order deadlocks.
  def test_check_nested_synchronize_wire_returns_result
    client = wire_locked_orwdxc_accept_client([ ORDINARY_LOW_CHECK ])
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = RpmsRpc.synchronize_wire do
      RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    end

    assert result.available?
    assert result.complete?
    refute result.override_required?
  end

  def test_check_concurrent_with_host_synchronize_wire_finishes_without_deadlock
    client = wire_locked_orwdxc_accept_client([ ORDINARY_LOW_CHECK ], rpc_sleep: 0.05)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }

    result_a = nil
    result_b = nil
    errors = []
    thread_a = nil
    thread_b = Thread.new do
      RpmsRpc.synchronize_wire do
        sleep 0.05
        result_b = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
      end
    rescue StandardError => e
      errors << e
    end

    sleep 0.01

    thread_a = Thread.new do
      result_a = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    rescue StandardError => e
      errors << e
    end

    threads = [ thread_a, thread_b ]
    begin
      threads.each do |thread|
        assert thread.join(WIRE_LOCK_DEADLOCK_JOIN_LIMIT),
               "thread #{thread} did not finish within #{WIRE_LOCK_DEADLOCK_JOIN_LIMIT}s (wire/check lock inversion?)"
      end
      assert_empty errors, errors.map(&:message).join("; ")
      assert result_a&.available?
      assert result_b&.available?
    ensure
      threads.each { |thread| thread.kill if thread&.alive? }
      threads.each { |thread| thread.join(0.1) }
    end
  end

  def test_check_fail_closed_malformed_reply_with_incomplete_banner_still_memoizes_dfn
    with_orwdxc_accept_sequence([
      [ FDB_INCOMPLETE_BANNER, MALFORMED_CHK2LST_ROW ],
      [ ORDINARY_LOW_CHECK ]
    ])

    first = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    refute first.available?
    assert first.override_required?
    assert_empty first.checks

    second = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    assert second.available?
    refute second.complete?
    assert second.override_required?
    session_reason = second.incomplete_reason.to_s
    assert_match(/incomplete/i, session_reason)
    assert_match(/session/i, session_reason)
  end

  def test_check_fail_closed_remote_checking_row_malformed_reply_still_memoizes_dfn
    with_orwdxc_accept_sequence([
      [ REMOTE_CHECKING_UNAVAILABLE_ROW, MALFORMED_CHK2LST_ROW ],
      [ ORDINARY_LOW_CHECK ]
    ])

    first = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    refute first.available?
    assert_empty first.checks

    second = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    assert second.available?
    refute second.complete?
    assert second.override_required?
  end

  def test_check_empty_reply_does_not_taint_opos_session_memo_for_dfn
    with_orwdxc_accept_sequence([
      [],
      [ ORDINARY_LOW_CHECK ]
    ])

    first = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    refute first.available?
    assert_empty first.checks

    second = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    assert second.available?
    assert second.complete?
    refute second.override_required?
  end

  def test_check_mixed_incomplete_and_ordinary_checks_stays_available_but_incomplete
    with_orwdxc_accept_wire([
      "NEW^401^1^High severity synthetic alert",
      "NEW^25^2^||66000,123,NEW&These checks could not be completed for this patient:"
    ])

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    assert result.available?
    refute result.complete?
    assert result.override_required?
    assert_equal 2, result.checks.length
    refute result.checks.first.incomplete?
    assert result.checks.last.incomplete?
  end

  def test_check_unavailable_result_is_not_complete
    with_orwdxc_accept_wire([])
    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    refute result.available?
    refute result.complete?
  end

  def test_check_parses_extended_text_prefix_into_text_and_key
    key = "66000,1001,NEW"
    headline = "Synthetic extended-text headline"
    with_orwdxc_accept_wire([ "NEW^410^2^||#{key}&#{headline}" ])

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    check = result.checks.first
    assert_equal headline, check.text
    assert_equal key, check.extended_text_key
    refute check.incomplete?
  end

  def test_check_plain_text_has_no_extended_text_key
    with_orwdxc_accept_wire([ "NEW^401^1^High severity synthetic alert" ])

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    check = result.checks.first
    assert_equal "High severity synthetic alert", check.text
    assert_nil check.extended_text_key
  end

  def test_check_cdl_99_is_unknown_severity_and_requires_override
    with_orwdxc_accept_wire([ "NEW^601^99^Danger level unknown on wire" ])

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    assert result.available?
    assert result.override_required?
    check = result.checks.first
    assert_equal :unknown, check.severity
    assert check.override_required?
  end

  def test_check_missing_or_non_numeric_cdl_is_unknown_and_requires_override
    with_orwdxc_accept_wire([
      "NEW^701^^Missing CDL piece",
      "NEW^702^xy^Non-numeric CDL"
    ])

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    assert result.available?
    assert result.override_required?
    assert result.checks.all? { |c| c.severity == :unknown }
  end

  # YDB-served broker CHK2LST replies use bare CR between rows; call_rpc returns
  # one String (XwbClient#split_response keeps it as a single element when no LF).
  def test_check_bare_cr_string_reply_splits_rows_and_requires_override
    with_orwdxc_accept_reply(BARE_CR_TWO_ROW_REPLY)

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    assert result.available?
    assert result.complete?
    assert result.override_required?

    by_severity = result.checks.group_by(&:severity)
    assert_equal 1, by_severity[:low].length
    assert_equal 1, by_severity[:high].length
    assert_equal "Synthetic low check", by_severity[:low].first.text
    assert_equal "Synthetic HIGH interaction", by_severity[:high].first.text
    assert by_severity[:high].first.override_required?
    refute by_severity[:low].first.override_required?
  end

  def test_check_bare_cr_one_element_array_reply_splits_rows_and_requires_override
    with_orwdxc_accept_reply([ BARE_CR_TWO_ROW_REPLY ])

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    assert result.available?
    assert result.complete?
    assert result.override_required?
    assert_equal %i[high low], result.checks.map(&:severity).sort
  end

  def test_check_mixed_crlf_cr_lf_row_separators_split_every_row
    reply = "NEW^11^3^Synthetic low after CRLF\r\n" \
            "NEW^12^2^Synthetic moderate after bare CR\r" \
            "NEW^13^1^Synthetic high after bare LF\n"

    with_orwdxc_accept_reply(reply)

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    assert result.available?
    assert result.complete?
    assert result.override_required?
    assert_equal 3, result.checks.length
    assert_equal %i[high low moderate], result.checks.map(&:severity).sort
  end

  def test_check_row_text_with_embedded_control_character_fails_closed
    cases = [
      "NEW^5^3^Synthetic\x00 low check",
      "NEW^9^1^Synthetic\x1E HIGH interaction"
    ]

    cases.each do |row|
      with_orwdxc_accept_reply(row)
      result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

      refute result.available?
      assert result.override_required?
      assert_empty result.checks
      assert_match(/unavailable/i, result.unavailable_reason.to_s)
    end
  end

  def test_check_invalid_utf8_reply_line_fails_closed_without_argument_error
    row = "NEW^5^3^bad\xFF".dup.force_encoding("UTF-8")
    with_orwdxc_accept_reply(row)

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    refute result.available?
    assert result.override_required?
    assert_empty result.checks
    reason = result.unavailable_reason.to_s
    assert_match(/unavailable/i, reason)
    assert_match(/malformed/i, reason)
  end

  # --- fail closed: empty / bad wire -------------------------------------------

  def test_check_empty_reply_is_unavailable_not_zero_checks
    [ [], "", nil ].each do |empty|
      with_orwdxc_accept_wire(empty)
      result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

      refute result.available?
      assert result.override_required?
      assert_empty result.checks
      reason = result.unavailable_reason.to_s
      assert_match(/checks unavailable/i, reason)
      refute_match(/no checks found/i, reason)
      refute_match(/zero checks/i, reason)
    end
  end

  def test_check_unparseable_rows_make_whole_result_unavailable
    cases = [
      [ "NEW^401^1" ], # fewer than four ^ pieces
      [ "NEW^abc^1^Bad check IEN" ],
      [ "NEW^401^1^Good", "truncated" ]
    ]

    cases.each do |lines|
      with_orwdxc_accept_wire(lines)
      result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

      refute result.available?
      assert result.override_required?
      assert_empty result.checks
      assert_match(/unavailable/i, result.unavailable_reason.to_s)
    end
  end

  # CHK2LST skips rows with a blank CDL piece (FOIA ORWDXC.m:145, stock :151), so
  # ORKCHK RETURN's NEW^^99^Order Checking Unavailable rows normally never reach
  # the client; this still fails closed if one does (ORKCHK.m:20-21).
  def test_check_order_checking_unavailable_row_fails_closed
    msg = "Order Checking Unavailable - invalid patient id"
    with_orwdxc_accept_wire([ "NEW^^99^#{msg}" ])

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    refute result.available?
    assert result.override_required?
    assert_empty result.checks
    reason = result.unavailable_reason.to_s
    assert_match(/checks unavailable/i, reason)
    assert_includes reason, msg
  end

  # --- argument guards (invalid_id? in order.rb) --------------------------------

  def test_check_invalid_dfn_or_empty_items_never_calls_rpc
    client = no_wire_client
    RpmsRpc.configure { |c| c.client = client }

    [ nil, "", "   ", "0", -1, "abc" ].each do |bad_dfn|
      result = RpmsRpc::Order.check(bad_dfn, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
      refute result.available?
      assert result.override_required?
      assert_match(/unavailable/i, result.unavailable_reason.to_s)
    end

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [])
    refute result.available?
    assert_empty client.calls
  end

  def test_check_invalid_orderable_item_first_piece_never_calls_rpc
    client = no_wire_client
    RpmsRpc.configure { |c| c.client = client }

    [
      [ "bogus^PS^2" ],
      [ ITEM_ONE, "bogus^PS^2" ],
      [ { orderable_item: "abc", package: "PS", package_info: "" } ]
    ].each do |items|
      client.calls.clear
      result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: items)
      refute result.available?
      assert result.override_required?
      assert_empty client.calls
    end
  end

  def test_check_invalid_oil_package_or_pkginfo_never_calls_rpc
    client = no_wire_client
    RpmsRpc.configure { |c| c.client = client }

    invalid_items = [
      [ "1002" ],
      [ "1001^ps^2001" ],
      [ "1001^PS^Synthetic outpatient sig" ],
      [ "1001^PSO^" ],
      [ "1001^PSH^not-a-number" ],
      [ "2002^PSIV^IV bag" ],
      [ "2002^PSIV^B;" ],
      [ "2002^PSIV^C" ],
      [ "2002^PSIV^B;1|2" ],
      [ { orderable_item: "2001", package: "PS", package_info: "Tablet sig" } ],
      [ { orderable_item: "2002", package: "PSIV", package_info: "IV bag" } ]
    ]

    invalid_items.each do |items|
      client.calls.clear
      result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: items)
      refute result.available?
      assert result.override_required?
      assert_empty client.calls
    end
  end

  def test_check_non_ps_package_accepts_arbitrary_pkginfo_without_pipe
    with_orwdxc_accept_wire([ ORDINARY_LOW_CHECK ])

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_TWO ])

    assert result.available?
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWDXC ACCEPT" }
    refute_nil call
    assert_oil_list_param(call[:params][4], [ ITEM_TWO ])
  end

  def test_check_psiv_valid_pkginfo_shapes_call_rpc
    with_orwdxc_accept_wire([ ORDINARY_LOW_CHECK ])

    (%w[A B B;100 B;12.5 B;0] + [ "B;1000 ML" ]).each do |pkginfo|
      RpmsRpc.reset!
      with_orwdxc_accept_wire([ ORDINARY_LOW_CHECK ])
      items = [ { orderable_item: "2002", package: "PSIV", package_info: pkginfo } ]
      result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: items)
      assert result.available?
      call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWDXC ACCEPT" }
      assert_oil_list_param(call[:params][4], [ "2002^PSIV^#{pkginfo}" ])
    end
  end

  def test_check_invalid_filler_id_never_calls_rpc
    client = no_wire_client
    RpmsRpc.configure { |c| c.client = client }

    %w[PS|X ps OR^1].each do |bad_filler_id|
      client.calls.clear
      result = RpmsRpc::Order.check(DFN, filler_id: bad_filler_id, location: LOCATION, items: [ ITEM_ONE ])
      refute result.available?
      assert_empty client.calls
    end
  end

  def test_check_non_canonical_dfn_or_location_never_calls_rpc
    client = no_wire_client
    RpmsRpc.configure { |c| c.client = client }

    [ "8791abc", " 5", "1.5" ].each do |bad_id|
      client.calls.clear
      result = RpmsRpc::Order.check(bad_id, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
      refute result.available?
      assert_empty client.calls

      client.calls.clear
      result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: bad_id, items: [ ITEM_ONE ])
      refute result.available?
      assert_empty client.calls
    end
  end

  def test_check_positive_integer_dfn_and_location_still_call_rpc
    with_orwdxc_accept_wire([ "NEW^502^3^Low only" ])

    RpmsRpc::Order.check(8791, filler_id: FILLER_ID, location: 349, items: [ ITEM_ONE ])

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWDXC ACCEPT" }
    refute_nil call
    assert_equal "8791", call[:params][0]
    assert_equal "349", call[:params][3]
  end

  # --- broker errors propagate (same as other Order DataMapper reads) ---------

  def test_check_rpc_not_available_error_propagates
    # Same contract as other Order reads: broker errors are not swallowed into
    # an empty check list (#454 fail closed applies to check *replies*, not RPC faults).
    assert_respond_to RpmsRpc::Order, :check

    message = "3 Unknown remote procedure: ORWDXC ACCEPT"
    client = Class.new do
      define_method(:call_rpc) { |*, **| raise RpmsRpc::Client::RpcNotAvailableError, message }
      define_method(:call_rpc_lines) { |*, **| raise RpmsRpc::Client::RpcNotAvailableError, message }
      define_method(:call_rpc_global_array) { |*, **| raise RpmsRpc::Client::RpcNotAvailableError, message }
    end.new
    RpmsRpc.configure { |c| c.client = client }

    error = assert_raises(RpmsRpc::Client::RpcNotAvailableError) do
      RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    end
    assert_equal message, error.message
  end

  # --- retry safety / compatibility registry ------------------------------------

  def test_check_is_non_idempotent_write
    # Stock ACCEPT calls OPOS (ORWDXC.m:53, 214-229), which writes session state
    # ^TMP($J,"OC-OPOS",DFN); a repeat ACCEPT in the same session omits the
    # incomplete-checks notice, so automatic read retries are unsafe.
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(RpmsRpc::Order, :check)
  end

  def test_required_rpcs_includes_orwdxc_accept_on_order
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    rpcs = doc.fetch("modules").fetch("RpmsRpc::Order")
    assert_includes rpcs, "ORWDXC ACCEPT"
  end

  private

  def assert_accept_fault_after_opos_still_memoizes_dfn(error_class, message)
    with_orwdxc_accept_raise_then_sequence(error_class, message, [
      [ ORDINARY_LOW_CHECK ],
      [ ORDINARY_LOW_CHECK ]
    ])

    error = assert_raises(error_class) do
      RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    end
    assert_equal message, error.message

    second = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    assert second.available?
    refute second.complete?
    assert second.override_required?
    session_reason = (second.incomplete_reason || second.session_incomplete_reason).to_s
    assert_match(/incomplete/i, session_reason)
    assert_match(/session/i, session_reason)

    third = RpmsRpc::Order.check(DFN_B, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])
    assert third.available?
    assert third.complete?
  end

  def assert_oil_list_param(param, expected_rows)
    entries = list_param_entries(param)
    expected = expected_rows.each_with_index.to_h { |row, i| [ (i + 1).to_s, row ] }
    assert_equal expected, entries
  end

  def list_param_entries(param)
    case param
    when Hash
      return param[:entries] if param[:type] == :list

      param.transform_keys(&:to_s)
    when Array
      param.each_with_index.to_h { |row, i| [ (i + 1).to_s, row.to_s ] }
    else
      flunk "expected OIL list param, got #{param.inspect}"
    end
  end

  def with_orwdxc_accept_wire(lines)
    wire = lines.nil? ? nil : Array(lines)
    with_orwdxc_accept_sequence([ wire ])
  end

  # Returns the ORWDXC ACCEPT reply exactly as call_rpc would (String or Array).
  def with_orwdxc_accept_reply(reply)
    with_orwdxc_accept_sequence([ reply ])
  end

  def with_orwdxc_accept_sequence(wires)
    client = RpmsRpc::MockClient.new
    queue = wires.map { |wire| wire.nil? ? nil : wire }
    %i[call_rpc call_rpc_lines call_rpc_global_array].each do |meth|
      client.define_singleton_method(meth) do |rpc_name, *params|
        received_calls << { rpc: rpc_name, params: params, context: current_context }
        raise "unexpected RPC #{rpc_name.inspect}" unless rpc_name == "ORWDXC ACCEPT"

        if queue.empty?
          raise "unexpected extra ORWDXC ACCEPT call"
        end

        queue.shift
      end
    end
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def with_orwdxc_accept_raise_then_sequence(error_class, message, subsequent_wires)
    client = RpmsRpc::MockClient.new
    queue = subsequent_wires.map { |wire| wire.nil? ? nil : wire }
    first_accept = true
    %i[call_rpc call_rpc_lines call_rpc_global_array].each do |meth|
      client.define_singleton_method(meth) do |rpc_name, *params|
        received_calls << { rpc: rpc_name, params: params, context: current_context }
        raise "unexpected RPC #{rpc_name.inspect}" unless rpc_name == "ORWDXC ACCEPT"

        if first_accept
          first_accept = false
          raise error_class, message
        end

        if queue.empty?
          raise "unexpected extra ORWDXC ACCEPT call"
        end

        queue.shift
      end
    end
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def no_wire_client
    Class.new do
      attr_reader :calls

      def initialize = @calls = []

      %i[call_rpc call_rpc_lines call_rpc_global_array].each do |meth|
        define_method(meth) do |rpc, *params|
          @calls << [ rpc, *params ]
          raise "RPC must not run for invalid Order.check arguments"
        end
      end
    end.new
  end

  # Like XwbClient#wire_operation: call_rpc holds the same reentrant Monitor as #synchronize_wire.
  def wire_locked_orwdxc_accept_client(lines, rpc_sleep: 0.01)
    wire_lock = Monitor.new
    reply = Array(lines)
    Class.new do
      define_method(:synchronize_wire) { |&block| wire_lock.synchronize(&block) }

      %i[call_rpc call_rpc_lines call_rpc_global_array].each do |meth|
        define_method(meth) do |rpc_name, *_params|
          raise "unexpected RPC #{rpc_name.inspect}" unless rpc_name == "ORWDXC ACCEPT"

          wire_lock.synchronize do
            sleep rpc_sleep
            reply
          end
        end
      end
    end.new
  end
end
