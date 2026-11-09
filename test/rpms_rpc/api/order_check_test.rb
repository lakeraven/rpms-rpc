# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "monitor"
require "rpms_rpc"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/order"
require_relative "../captured_replies"

# rpms-rpc#454: Order.check over ORWDXC ACCEPT (CHK2LST reply, ORWDXC.m:138-147).
#
# The broker formal list is ACCEPT(LST,DFN,FID,STRT,ORL,OIL,ORIFN) (ORWDXC.m:45),
# seven client actuals after LST (stock VistA adds an unread 8th ORREN). FID is
# the filler namespace from FILLID^ORWDXC (ORWDXC.m:7-16), not the dialog IEN.
# OIL(n) is OIptr^PKG^PkgInfo (ORWDXC.m:46).
#
# Replies are the pinned build's (test/fixtures/captured_replies/order-write.yml),
# replayed through CiaClient: Order.check for the build's one drug orderable
# and for a lab orderable, recorded as flows, and the broker's refusal of an
# RPC it does not serve. The build answers every ACCEPT with no rows, so no
# order check is live-proven (rpms-rpc#383). The guards on check rows keep the
# captured ACCEPT frame and put CHK2LST rows in its body, in the format
# ORWDXC.m:138-147 writes (ORDER^CHECK IEN^CDL^TEXT); each test names them.
class OrderCheckTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")
  RPC = "ORWDXC ACCEPT"
  SLUG = "order-write"

  DRUG_CHECK = CapturedReplies.flow_calls(SLUG, "check_drug").first.last
  DFN, FILLER_ID, _START, LOCATION = DRUG_CHECK.first(4)
  ITEM_ONE = DRUG_CHECK[4].first
  ITEM_TWO = "450^LR^"
  DFN_B = "990034"

  FDB_INCOMPLETE_BANNER = "NEW^25^2^||66000,123,NEW&These checks could not be completed for this patient:"
  REMOTE_CHECKING_UNAVAILABLE_ROW = "NEW^99^2^Remote Order Checking not available - checks done on local data only"
  HIGH_CHECK = "NEW^401^1^High severity alert"
  MODERATE_CHECK = "123;1^402^2^Moderate alert on existing order"
  LOW_CHECK = "NEW^502^3^Low only"
  MALFORMED_ROW = "NEW^17"

  CONCURRENT_JOIN_LIMIT = 5
  WIRE_LOCK_DEADLOCK_JOIN_LIMIT = 3

  def teardown
    RpmsRpc.reset!
  end

  # The captured ACCEPT reply (no rows).
  def no_checks = CapturedReplies.flow_script(SLUG, "check_drug").fetch(RPC).first

  # The captured ACCEPT frame with CHK2LST rows in its body.
  def rows(*lines) = no_checks.byteslice(0, 2) + lines.map { |l| "#{l}\r" }.join.b

  def refused = CapturedReplies.raw(SLUG, "accept_unknown_rpc")

  # An M error frame as the build sends one (captured from BMC GET REFERRAL).
  def m_error = CapturedReplies.raw("bmc-get-referral", "m_error")

  def replay(*replies, client_class: CapturedReplies::ReplayCiaClient)
    @client = client_class.new(RPC => replies)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = @client }
    @client
  end

  def check(dfn = DFN, items: [ ITEM_ONE ])
    RpmsRpc::Order.check(dfn, filler_id: FILLER_ID, location: LOCATION, items: items)
  end

  def accept_params = @client.calls.find { |c| c[:rpc] == RPC }[:params]

  # --- RPC frame (ORWDXC ACCEPT) ------------------------------------------------

  def test_check_sends_the_formals_the_build_answered
    replay(no_checks)

    RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION,
                              items: [ { orderable_item: "1521", package: "PS", package_info: "1" } ])

    assert_equal DRUG_CHECK, accept_params
  end

  def test_check_sends_start_order_id_and_every_oil_row
    replay(no_checks)

    RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE, ITEM_TWO ],
                              start: "NEXT", order_id: "5001;1")

    assert_equal [ DFN, FILLER_ID, "NEXT", LOCATION, [ ITEM_ONE, ITEM_TWO ], "5001;1" ], accept_params
  end

  def test_check_joins_hash_items_into_oil_caret_rows
    replay(no_checks)

    check(items: [ { orderable_item: "2001", package: "PS", package_info: "2001" },
                   { orderable_item: "2002", package: "PSIV", package_info: "B;100" } ])

    assert_equal [ "2001^PS^2001", "2002^PSIV^B;100" ], accept_params[4]
  end

  # --- the build's reply: no rows ------------------------------------------------

  # ACCEPT answered no rows. That is not "no checks found": it fails closed.
  def test_check_empty_reply_is_unavailable_not_zero_checks
    replay(no_checks)

    result = check

    refute result.available?
    refute result.complete?
    assert result.override_required?
    assert_empty result.checks
    assert_match(/checks unavailable/i, result.unavailable_reason.to_s)
    refute_match(/no checks found|zero checks/i, result.unavailable_reason.to_s)
  end

  def test_check_rpc_not_available_error_propagates
    replay(refused)

    assert_raises(RpmsRpc::Client::RpcNotAvailableError) { check }
  end

  # --- CHK2LST rows (guards on the captured frame) --------------------------------

  # Rows: HIGH_CHECK, MODERATE_CHECK, LOW_CHECK.
  def test_check_parses_high_moderate_and_low_rows_and_requires_override_for_high
    replay(rows(HIGH_CHECK, MODERATE_CHECK, LOW_CHECK))

    result = check

    assert result.available?
    assert result.override_required?
    by_severity = result.checks.group_by(&:severity)
    assert_equal %i[high low moderate], by_severity.keys.sort
    high = by_severity[:high].first
    assert_equal [ "NEW", "401", "High severity alert" ], [ high.order_id, high.check_ien, high.text ]
    assert high.override_required?
    refute by_severity[:moderate].first.override_required?
  end

  # Rows: MODERATE_CHECK, LOW_CHECK.
  def test_check_moderate_and_low_only_is_complete_without_override
    replay(rows(MODERATE_CHECK, LOW_CHECK))

    result = check

    assert result.available?
    assert result.complete?
    refute result.override_required?
  end

  # Row: FDB_INCOMPLETE_BANNER, with its extended-text key.
  def test_check_fdb_down_incomplete_banner_is_incomplete_and_requires_override
    replay(rows(FDB_INCOMPLETE_BANNER))

    result = check

    assert result.available?
    refute result.complete?
    assert result.override_required?
    banner = result.checks.first
    assert banner.incomplete?
    assert_equal "These checks could not be completed for this patient:", banner.text
    assert_equal "66000,123,NEW", banner.extended_text_key
  end

  # Row: REMOTE_CHECKING_UNAVAILABLE_ROW.
  def test_check_remote_order_checking_unavailable_row_is_incomplete
    replay(rows(REMOTE_CHECKING_UNAVAILABLE_ROW))

    result = check

    assert result.available?
    refute result.complete?
    assert result.override_required?
  end

  # Rows with CDL 99, blank and "xy": unknown severity, override required.
  def test_check_unknown_cdl_requires_override
    replay(rows("NEW^601^99^Danger level unknown", "NEW^701^^Missing CDL", "NEW^702^xy^Non-numeric CDL"))

    result = check

    assert result.override_required?
    assert(result.checks.all? { |c| c.severity == :unknown })
  end

  # Rows that are not CHK2LST rows make the whole result unavailable: too few
  # pieces, a check IEN that is not a number, a truncated row, a $C(30) left in a
  # row, a byte that is not UTF-8. (CiaClient turns a NUL into a space, so a NUL
  # never reaches the parser over CIA.)
  def test_check_unparseable_rows_make_whole_result_unavailable
    [ [ "NEW^401^1" ], [ "NEW^abc^1^Bad check IEN" ], [ HIGH_CHECK, "truncated" ],
      [ "NEW^9^1^HIGH\x1E interaction" ], [ "NEW^5^3^bad\xFF" ] ].each do |lines|
      replay(rows(*lines))

      result = check

      refute result.available?, lines.inspect
      assert result.override_required?
      assert_empty result.checks
    end
  end

  # Row: ORKCHK's "NEW^^99^Order Checking Unavailable" (ORKCHK.m:20-21).
  def test_check_order_checking_unavailable_row_fails_closed
    msg = "Order Checking Unavailable - invalid patient id"
    replay(rows("NEW^^99^#{msg}"))

    result = check

    refute result.available?
    assert result.override_required?
    assert_includes result.unavailable_reason.to_s, msg
  end

  # --- OPOS session memo (ORWDXC.m:53, 214-229) -----------------------------------
  #
  # ACCEPT runs OPOS before CHK2LST, which writes ^TMP($J,"OC-OPOS",DFN) and
  # drops the incomplete-checks banner on a later ACCEPT in that broker job. The
  # client remembers the DFN so a later result for it stays incomplete.

  def test_check_opos_session_memo_banner_omitted_later_still_incomplete
    [ FDB_INCOMPLETE_BANNER, REMOTE_CHECKING_UNAVAILABLE_ROW ].each do |banner|
      replay(rows(banner, LOW_CHECK), rows(LOW_CHECK), rows(LOW_CHECK))

      refute check.complete?
      second = check
      refute second.complete?
      assert second.override_required?
      assert_match(/incomplete.*session|session.*incomplete/i, second.incomplete_reason.to_s)
      assert check(DFN_B).complete?, "another DFN is not affected"
    end
  end

  # A malformed reply that still carried the banner memoizes the DFN.
  def test_check_malformed_reply_with_incomplete_banner_still_memoizes_dfn
    replay(rows(FDB_INCOMPLETE_BANNER, MALFORMED_ROW), rows(LOW_CHECK))

    refute check.available?
    second = check
    refute second.complete?
    assert second.override_required?
  end

  # The build's empty reply does not taint the memo.
  def test_check_empty_reply_does_not_taint_opos_session_memo
    replay(no_checks, rows(LOW_CHECK))

    refute check.available?
    assert check.complete?
  end

  # An M error after OPOS: the routine ran, so the DFN is remembered.
  def test_check_m_error_during_accept_still_memoizes_dfn
    replay(m_error, rows(LOW_CHECK))

    assert_raises(RpmsRpc::Client::RpcError) { check }
    second = check
    refute second.complete?
    assert second.override_required?
  end

  # Not served: the routine never ran, so OPOS did not run.
  def test_check_rpc_not_available_error_does_not_memoize_dfn
    replay(refused, rows(LOW_CHECK))

    assert_raises(RpmsRpc::Client::RpcNotAvailableError) { check }
    assert check.complete?
  end

  # A timeout is not a reply: nothing says OPOS ran, so nothing is remembered.
  class TimingOutOnce < CapturedReplies::ReplayCiaClient
    def call_rpc_raw(rpc_name, *params)
      unless @timed_out
        @timed_out = true
        raise RpmsRpc::Client::TimeoutError, "RPC timeout"
      end
      super
    end
  end

  def test_check_timeout_during_accept_does_not_memoize_dfn
    replay(rows(LOW_CHECK), client_class: TimingOutOnce)

    assert_raises(RpmsRpc::Client::TimeoutError) { check }
    assert check.complete?
  end

  # Two threads on one DFN: the second ACCEPT waits for the first, so it sees
  # the memo the first left.
  class SlowFirstCall < CapturedReplies::ReplayCiaClient
    attr_reader :inside

    def initialize(...)
      super
      @inside = Queue.new
      @count = 0
    end

    def call_rpc_raw(rpc_name, *params)
      @count += 1
      if @count == 1
        @inside << true
        sleep 0.15
      end
      super
    end
  end

  def test_check_concurrent_same_dfn_blocks_until_first_finishes
    replay(rows(FDB_INCOMPLETE_BANNER, LOW_CHECK), rows(LOW_CHECK), client_class: SlowFirstCall)

    result_a = nil
    result_b = nil
    thread_a = Thread.new { result_a = check }
    @client.inside.pop
    thread_b = Thread.new { result_b = check }

    assert thread_a.join(CONCURRENT_JOIN_LIMIT), "thread A did not finish"
    assert thread_b.join(CONCURRENT_JOIN_LIMIT), "thread B did not finish"
    refute result_a.complete?
    refute result_b.complete?
    assert_match(/session/i, result_b.incomplete_reason.to_s)
  end

  # Order.check serializes on the client's reentrant wire lock (via
  # RpmsRpc.synchronize_wire), not a separate Mutex held across call_rpc, so a
  # host already inside synchronize_wire re-enters instead of deadlocking.
  def test_check_nested_synchronize_wire_returns_result
    replay(rows(LOW_CHECK))

    result = RpmsRpc.synchronize_wire { check }

    assert result.complete?
  end

  def test_check_concurrent_with_host_synchronize_wire_finishes_without_deadlock
    replay(rows(LOW_CHECK), rows(LOW_CHECK))
    errors = []
    thread_b = Thread.new do
      RpmsRpc.synchronize_wire do
        sleep 0.05
        check
      end
    rescue StandardError => e
      errors << e
    end
    sleep 0.01
    thread_a = Thread.new do
      check
    rescue StandardError => e
      errors << e
    end

    [ thread_a, thread_b ].each do |thread|
      assert thread.join(WIRE_LOCK_DEADLOCK_JOIN_LIMIT), "a thread did not finish (wire/check lock inversion?)"
    end
    assert_empty errors, errors.map(&:message).join("; ")
  ensure
    [ thread_a, thread_b ].compact.each { |t| t.kill if t.alive? }
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


  def test_check_valid_pkginfo_shapes_call_rpc
    ([ ITEM_TWO, "1001^LR^Synthetic lab orderable" ] +
      (%w[A B B;100 B;12.5 B;0] + [ "B;1000 ML" ]).map { |info| "2002^PSIV^#{info}" }).each do |item|
      replay(no_checks)
      check(items: [ item ])
      assert_equal [ item ], accept_params[4]
    end
  end

  def test_check_positive_integer_dfn_and_location_still_call_rpc
    replay(no_checks)

    RpmsRpc::Order.check(DFN.to_i, filler_id: FILLER_ID, location: LOCATION.to_i, items: [ ITEM_ONE ])

    assert_equal [ DFN, LOCATION ], accept_params.values_at(0, 3)
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
    assert_includes doc.fetch("modules").fetch("RpmsRpc::Order"), RPC
  end

  private

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
end
