# frozen_string_literal: true

require "minitest/autorun"
require "json"
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
  ITEM_ONE = "1001^PS^Synthetic outpatient sig"
  ITEM_TWO = "1002^LR^Synthetic lab orderable"

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
      { orderable_item: "2001", package: "PS", package_info: "Tablet sig" },
      { orderable_item: "2002", package: "PSIV", package_info: "IV bag" }
    ]

    RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: items)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWDXC ACCEPT" }
    assert_oil_list_param(call[:params][4], [ "2001^PS^Tablet sig", "2002^PSIV^IV bag" ])
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

  def test_check_order_checking_unavailable_row_fails_closed
    msg = "Order Checking Unavailable - invalid patient id"
    with_orwdxc_accept_wire([ "NEW^^99^#{msg}" ])

    result = RpmsRpc::Order.check(DFN, filler_id: FILLER_ID, location: LOCATION, items: [ ITEM_ONE ])

    refute result.available?
    assert result.override_required?
    assert_empty result.checks
    assert_includes result.unavailable_reason, msg
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

  def test_check_is_retry_safe_read
    assert_equal :read, RpmsRpc::RetrySafety.for(RpmsRpc::Order, :check)
  end

  def test_required_rpcs_includes_orwdxc_accept_on_order
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    rpcs = doc.fetch("modules").fetch("RpmsRpc::Order")
    assert_includes rpcs, "ORWDXC ACCEPT"
  end

  private

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
    client = RpmsRpc::MockClient.new
    wire = lines.nil? ? nil : Array(lines)
    %i[call_rpc call_rpc_lines call_rpc_global_array].each do |meth|
      client.define_singleton_method(meth) do |rpc_name, *params|
        received_calls << { rpc: rpc_name, params: params, context: current_context }
        raise "unexpected RPC #{rpc_name.inspect}" unless rpc_name == "ORWDXC ACCEPT"

        wire
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
end
