# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/order"

# rpms-rpc#456: Order.sign_and_release over ORWU VALIDSIG then ORWDX SEND
# (SEND^ORWDX → SEND1^ORWDX → EN^ORCSEND; FOIA-RPMS ORWDX.m:152-178).
#
# Broker formals SEND(ORWLST,DFN,ORNP,ORL,ES,ORWREC) (ORWDX.m:152-154):
# ES is the encrypted signature code; ORWREC(n)=ORIFN;Action^Signature Sts^
# Release Sts^Nature (comment ORWDX.m:154). CHKACT^ORWDXR validates
# ORWSIG/ORWREL/ORWNATR before EN^ORCSEND (ORWDXR.m:87-98). Reply piece 2
# is built at ORWDX.m:172-176 ("R" when released, "S" when ORWSIG'=2).
# Per-order status: :released (piece 2 contains "R"), :signed (exactly "S"),
# :rejected (pre-send validation or ^E^ error row only), :unknown (SEND sent
# but reply does not prove that order's outcome).
class OrderSignAndReleaseTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")
  SEND_RPC = "ORWDX SEND"
  VALIDSIG_RPC = "ORWU VALIDSIG"

  DFN = "8791"
  PROVIDER_DUZ = "301"
  LOCATION = "349"
  SIG_CODE = "synthetic-es-code"
  ORDER_ONE = "10;1"
  ORDER_TWO = "11;1"

  ORWREC_ROW = "1^1^E" # ORWSIG=1 ES (ORWDXR.m:91), ORWREL=1, ORWNATR=E (electronic)

  def teardown
    RpmsRpc.reset!
  end

  # --- Kernel#send is not shadowed on Order (extend self) -----------------------

  def test_order_module_send_still_delegates_to_kernel_send
    assert RpmsRpc::Order.send(:respond_to?, :list)
  end

  # --- wire frame: VALIDSIG then ORWDX SEND -----------------------------------

  def test_sign_and_release_calls_validsig_before_orwdx_send_with_formal_order
    with_sign_release_wire(validsig: "1", send: [ "#{ORDER_ONE}^RS", "#{ORDER_TWO}^RS" ])

    RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE, ORDER_TWO ], SIG_CODE)

    calls = rpc_calls
    assert_equal [ VALIDSIG_RPC, SEND_RPC ], calls.map { |c| c[:rpc] }

    valid = calls[0]
    assert_equal 1, valid[:params].length
    refute_equal SIG_CODE, valid[:params][0]
    assert_equal SIG_CODE, RpmsRpc::XwbCipher.decrypt(valid[:params][0])

    send = calls[1]
    assert_equal 5, send[:params].length, "SEND(ORWLST,DFN,ORNP,ORL,ES,ORWREC) (ORWDX.m:152)"
    assert_equal DFN, send[:params][0]
    assert_equal PROVIDER_DUZ, send[:params][1]
    assert_equal LOCATION, send[:params][2]
    encrypted_es = send[:params][3]
    refute_equal SIG_CODE, encrypted_es
    assert_equal SIG_CODE, RpmsRpc::XwbCipher.decrypt(encrypted_es)
    assert_equal encrypted_es, valid[:params][0], "same encrypted token on VALIDSIG and SEND (vuecentric trace)"
    assert_orwrec_list_param(send[:params][4], [ "#{ORDER_ONE}^#{ORWREC_ROW}", "#{ORDER_TWO}^#{ORWREC_ROW}" ])
  end

  def test_sign_and_release_positive_integer_ids_still_call_rpc
    with_sign_release_wire(validsig: "1", send: [ "#{ORDER_ONE}^RS" ])

    RpmsRpc::Order.sign_and_release(8791, 301, 349, [ ORDER_ONE ], SIG_CODE)

    send = send_call
    assert_equal "8791", send[:params][0]
    assert_equal "301", send[:params][1]
    assert_equal "349", send[:params][2]
  end

  # --- reply parsing (ORWLST / ORWDX.m:172-176) --------------------------------

  def test_sign_and_release_released_when_reply_piece_two_contains_r
    with_sign_release_wire(validsig: "1", send: [ "#{ORDER_ONE}^RS", "#{ORDER_TWO}^RS" ])

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE, ORDER_TWO ], SIG_CODE)

    assert_equal 2, results.length
    released = results.find { |r| r[:order_id] == ORDER_ONE }
    refute_nil released
    assert_equal :released, released[:status]
    assert_nil released[:reason]
    assert_equal :released, results.find { |r| r[:order_id] == ORDER_TWO }[:status]
    refute_signature_leaked(results, SIG_CODE)
  end

  def test_sign_and_release_signed_only_s_is_signed_not_released
    with_sign_release_wire(validsig: "1", send: [ "#{ORDER_ONE}^S" ])

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    row = results.fetch(0)
    assert_equal ORDER_ONE, row[:order_id]
    assert_equal :signed, row[:status]
    assert_match(/signed/i, row[:reason])
    assert_match(/not released/i, row[:reason])
    refute_equal :released, row[:status]
  end

  def test_sign_and_release_error_row_parses_orwerr_text
    msg = "Synthetic order cannot be released"
    with_sign_release_wire(validsig: "1", send: [ "#{ORDER_ONE}^E^1^#{msg}" ])

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    row = results.fetch(0)
    assert_equal :rejected, row[:status]
    assert_equal msg, row[:reason]
  end

  def test_sign_and_release_mixed_crlf_cr_lf_row_separators
    reply = "#{ORDER_ONE}^RS\r\n#{ORDER_TWO}^RS\r"

    with_sign_release_reply(validsig: "1", send: reply)

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE, ORDER_TWO ], SIG_CODE)

    assert_equal :released, results.find { |r| r[:order_id] == ORDER_ONE }[:status]
    assert_equal :released, results.find { |r| r[:order_id] == ORDER_TWO }[:status]
  end

  def test_sign_and_release_bare_cr_string_reply_splits_rows
    reply = "#{ORDER_ONE}^RS\r#{ORDER_TWO}^RS"
    with_sign_release_reply(validsig: "1", send: reply)

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE, ORDER_TWO ], SIG_CODE)

    assert results.all? { |r| r[:status] == :released }
  end

  def test_sign_and_release_bare_lf_string_reply_splits_rows
    reply = "#{ORDER_ONE}^RS\n#{ORDER_TWO}^RS\n"
    with_sign_release_reply(validsig: "1", send: reply)

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE, ORDER_TWO ], SIG_CODE)

    assert results.all? { |r| r[:status] == :released }
  end

  # --- SEND sent but reply does not prove per-order outcome (:unknown) ---------

  def test_sign_and_release_empty_send_reply_unknown_every_order
    [ [], "", nil ].each do |empty|
      RpmsRpc.reset!
      with_sign_release_wire(validsig: "1", send: empty)

      results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE, ORDER_TWO ], SIG_CODE)

      assert_equal 2, results.length
      results.each do |row|
        assert_equal :unknown, row[:status], empty.inspect
        assert_unknown_outcome_reason(row[:reason])
      end
      refute results.any? { |r| r[:status] == :released }
      refute results.any? { |r| r[:status] == :rejected }
    end
  end

  def test_sign_and_release_missing_row_for_requested_order_is_unknown
    with_sign_release_wire(validsig: "1", send: [ "#{ORDER_ONE}^RS" ])

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE, ORDER_TWO ], SIG_CODE)

    assert_equal :released, results.find { |r| r[:order_id] == ORDER_ONE }[:status]
    missing = results.find { |r| r[:order_id] == ORDER_TWO }
    refute_nil missing
    assert_equal :unknown, missing[:status]
    assert_unknown_outcome_reason(missing[:reason])
  end

  def test_sign_and_release_duplicate_reply_rows_unknown_that_order
    with_sign_release_wire(validsig: "1", send: [ "#{ORDER_ONE}^RS", "#{ORDER_ONE}^RS" ])

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    assert_equal 1, results.length
    assert_equal :unknown, results[0][:status]
    assert_unknown_outcome_reason(results[0][:reason])
    refute_equal :released, results[0][:status]
  end

  def test_sign_and_release_unparseable_row_unknown_that_order
    with_sign_release_wire(validsig: "1", send: [ "not-a-order-row" ])

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    assert_equal 1, results.length
    assert_equal :unknown, results[0][:status]
    assert_unknown_outcome_reason(results[0][:reason])
  end

  def test_sign_and_release_unrecognised_piece_two_never_released
    [ "#{ORDER_ONE}^X", "#{ORDER_ONE}^" ].each do |reply_row|
      RpmsRpc.reset!
      with_sign_release_wire(validsig: "1", send: [ reply_row ])

      results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

      assert_equal :unknown, results[0][:status], reply_row
      assert_unknown_outcome_reason(results[0][:reason])
      refute_equal :released, results[0][:status]
    end
  end

  def test_sign_and_release_extra_row_for_unrequested_order_does_not_release_it
    with_sign_release_wire(validsig: "1", send: [ "#{ORDER_ONE}^RS", "99;1^RS" ])

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    assert_equal 1, results.length
    assert_equal :released, results[0][:status]
  end

  # --- VALIDSIG gate (exactly "1"; ORWDX SEND never called otherwise) ---------

  def test_sign_and_release_invalid_validsig_reply_rejects_orders_without_send
    [ "0", "", nil, "1 ", "-1^NOT AUTHORIZED" ].each do |bad|
      RpmsRpc.reset!
      with_sign_release_wire(validsig: bad, send: [ "#{ORDER_ONE}^RS" ])

      results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE, ORDER_TWO ], SIG_CODE)

      assert_empty rpc_calls.select { |c| c[:rpc] == SEND_RPC }, bad.inspect
      assert_equal 2, results.length
      results.each do |row|
        assert_equal :rejected, row[:status]
        assert_match(/signature/i, row[:reason])
        assert_match(/not accepted|invalid|rejected/i, row[:reason])
      end
      refute_signature_leaked(results, SIG_CODE)
    end
  end

  # --- argument validation (no RPC at all, not even VALIDSIG) -----------------

  def test_sign_and_release_invalid_arguments_never_call_rpc
    client = no_wire_client
    RpmsRpc.configure { |c| c.client = client }
    orders = [ ORDER_ONE ]

    [ nil, "", "   " ].each do |bad_sig|
      client.calls.clear
      results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, orders, bad_sig)
      assert_equal 1, results.length
      assert_equal :rejected, results[0][:status]
      assert results[0][:reason]
      assert_empty client.calls, bad_sig.inspect
      refute_signature_leaked(results, bad_sig) unless bad_sig.to_s.strip.empty?
    end

    [ nil, "", "0", "abc", "12abc", " 5" ].each do |bad_dfn|
      client.calls.clear
      results = RpmsRpc::Order.sign_and_release(bad_dfn, PROVIDER_DUZ, LOCATION, orders, SIG_CODE)
      assert_equal 1, results.length
      assert_equal :rejected, results[0][:status]
      assert_empty client.calls
    end

    [ nil, "", "0", "abc" ].each do |bad_duz|
      client.calls.clear
      results = RpmsRpc::Order.sign_and_release(DFN, bad_duz, LOCATION, orders, SIG_CODE)
      assert_equal 1, results.length
      assert_equal :rejected, results[0][:status]
      assert_empty client.calls
    end

    [ nil, "", "0", "abc" ].each do |bad_loc|
      client.calls.clear
      results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, bad_loc, orders, SIG_CODE)
      assert_equal 1, results.length
      assert_equal :rejected, results[0][:status]
      assert_empty client.calls
    end

    client.calls.clear
    assert_equal [], RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [], SIG_CODE)
    assert_empty client.calls

    [ "10;0", "0;1", "10", "10;1;2", "010;1", "10;01", "abc;1" ].each do |bad_id|
      client.calls.clear
      results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ bad_id ], SIG_CODE)
      assert_equal 1, results.length
      assert_equal :rejected, results[0][:status]
      assert_empty client.calls
    end

    client.calls.clear
    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE, ORDER_ONE ], SIG_CODE)
    assert_equal 2, results.length
    assert results.all? { |r| r[:status] == :rejected }
    assert_empty client.calls
  end

  # --- broker errors propagate --------------------------------------------------

  def test_sign_and_release_rpc_not_available_on_send_propagates
    assert_respond_to RpmsRpc::Order, :sign_and_release

    message = "3 Unknown remote procedure: ORWDX SEND"
    RpmsRpc.reset!
    RpmsRpc.configure { |c| c.client = sign_release_error_client(validsig: "1", send_error: RpmsRpc::Client::RpcNotAvailableError, message: message) }

    error = assert_raises(RpmsRpc::Client::RpcNotAvailableError) do
      RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)
    end
    assert_equal message, error.message
    refute_signature_in_exception(error, SIG_CODE)
  end

  def test_sign_and_release_rpc_refused_on_send_propagates
    assert_respond_to RpmsRpc::Order, :sign_and_release

    message = "4 Remote procedure not allowed for this user: ORWDX SEND"
    RpmsRpc.reset!
    RpmsRpc.configure { |c| c.client = sign_release_error_client(validsig: "1", send_error: RpmsRpc::Client::RpcRefusedError, message: message) }

    error = assert_raises(RpmsRpc::Client::RpcRefusedError) do
      RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)
    end
    assert_equal message, error.message
    refute_signature_in_exception(error, SIG_CODE)
  end

  def test_sign_and_release_rpc_error_on_send_propagates
    assert_respond_to RpmsRpc::Order, :sign_and_release

    message = "M  ERROR=synthetic fault in EN^ORCSEND"
    RpmsRpc.reset!
    RpmsRpc.configure { |c| c.client = sign_release_error_client(validsig: "1", send_error: RpmsRpc::Client::RpcError, message: message) }

    error = assert_raises(RpmsRpc::Client::RpcError) do
      RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)
    end
    assert_equal message, error.message
    refute_signature_in_exception(error, SIG_CODE)
  end

  def test_sign_and_release_send_error_after_validsig_does_not_leak_signature
    assert_respond_to RpmsRpc::Order, :sign_and_release

    message = "M  ERROR=synthetic fault after VALIDSIG"
    RpmsRpc.reset!
    RpmsRpc.configure do |c|
      c.client = sign_release_error_client(validsig: "1", send_error: RpmsRpc::Client::RpcError, message: message)
    end

    error = assert_raises(RpmsRpc::Client::RpcError) do
      RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)
    end
    assert_equal 1, RpmsRpc.client.received_calls.count { |c| c[:rpc] == VALIDSIG_RPC }
    refute_signature_in_exception(error, SIG_CODE)
  end

  def test_sign_and_release_rpc_not_available_on_validsig_propagates
    assert_respond_to RpmsRpc::Order, :sign_and_release

    message = "3 Unknown remote procedure: ORWU VALIDSIG"
    RpmsRpc.reset!
    client = Class.new do
      define_method(:call_rpc) { |*, **| raise RpmsRpc::Client::RpcNotAvailableError, message }
      define_method(:call_rpc_lines) { |*, **| raise RpmsRpc::Client::RpcNotAvailableError, message }
      define_method(:call_rpc_global_array) { |*, **| raise RpmsRpc::Client::RpcNotAvailableError, message }
    end.new
    RpmsRpc.configure { |c| c.client = client }

    error = assert_raises(RpmsRpc::Client::RpcNotAvailableError) do
      RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)
    end
    assert_equal message, error.message
  end

  # --- stock VistA namespace only ---------------------------------------------

  def test_sign_and_release_never_calls_ihs_beho_or_bgo_rpcs
    with_sign_release_wire(validsig: "1", send: [ "#{ORDER_ONE}^RS" ])

    RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    forbidden = rpc_calls.map { |c| c[:rpc] }.grep(/\A(BEHO|BGO)/)
    refute_empty rpc_calls
    assert_empty forbidden, "stock namespace must not call BEHO/BGO RPCs"
  end

  # --- retry safety / required RPC registry -------------------------------------

  def test_sign_and_release_is_non_idempotent_write
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(RpmsRpc::Order, :sign_and_release)
  end

  def test_required_rpcs_includes_orwdx_send_and_orwu_validsig_on_order
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    rpcs = doc.fetch("modules").fetch("RpmsRpc::Order")
    assert_includes rpcs, SEND_RPC
    assert_includes rpcs, VALIDSIG_RPC
  end

  private

  def rpc_calls
    RpmsRpc.client.received_calls
  end

  def send_call
    rpc_calls.find { |c| c[:rpc] == SEND_RPC }
  end

  def assert_orwrec_list_param(param, expected_rows)
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
      flunk "expected ORWREC list param, got #{param.inspect}"
    end
  end

  def assert_unknown_outcome_reason(reason)
    assert reason, "expected reason for :unknown outcome"
    assert_match(/unknown/i, reason)
    assert_match(/check.*order|order.*before.*retr/i, reason)
  end

  def refute_signature_in_exception(error, plaintext)
    encrypted = RpmsRpc::XwbCipher.encrypt(plaintext.to_s)
    refute_includes error.message, plaintext.to_s
    refute_includes error.message, encrypted
  end

  def refute_signature_leaked(value, plaintext, encrypted: nil)
    encrypted ||= RpmsRpc::XwbCipher.encrypt(plaintext.to_s)
    walk = []
    case value
    when Array
      value.each { |v| walk.concat(collect_strings(v)) }
    else
      walk = collect_strings(value)
    end
    blob = walk.join("\0")
    refute_includes blob, plaintext.to_s, "plaintext signature must not appear in results"
    refute_includes blob, encrypted, "encrypted signature must not appear in results"
  end

  def collect_strings(obj)
    case obj
    when String
      [ obj ]
    when Hash
      obj.flat_map { |k, v| [ collect_strings(k), collect_strings(v) ] }.flatten
    when Array
      obj.flat_map { |v| collect_strings(v) }
    when Symbol
      []
    when nil
      []
    else
      [ obj.to_s ]
    end
  end

  class SignatureCheckingClient
    def initialize(code:, valid_reply:, send_replies:)
      @code = code
      @valid_reply = valid_reply
      @send_queue = [ send_replies ]
      @calls = []
    end

    attr_reader :calls

    def received_calls = @calls
    def current_context = nil

    %i[call_rpc call_rpc_lines call_rpc_global_array].each do |meth|
      define_method(meth) do |rpc_name, *params|
        @calls << { rpc: rpc_name, params: params, context: current_context }
        case rpc_name
        when VALIDSIG_RPC
          wire = params.first.to_s
          decrypted = RpmsRpc::XwbCipher.decrypt(wire)
          return @valid_reply if decrypted == @code && @valid_reply == "1"
          return @valid_reply unless @valid_reply == "1"

          "0"
        when SEND_RPC
          raise "unexpected extra #{SEND_RPC}" if @send_queue.empty?

          @send_queue.shift
        else
          raise "unexpected RPC #{rpc_name.inspect}"
        end
      end
    end
  end

  def with_sign_release_wire(validsig:, send:)
    client = SignatureCheckingClient.new(code: SIG_CODE, valid_reply: validsig.to_s, send_replies: send)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def with_sign_release_reply(validsig:, send:)
    client = SignatureCheckingClient.new(code: SIG_CODE, valid_reply: validsig.to_s, send_replies: send)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sign_release_error_client(validsig:, send_error:, message:)
    Class.new do
      define_method(:received_calls) { @calls ||= [] }
      define_method(:current_context) { nil }

      %i[call_rpc call_rpc_lines call_rpc_global_array].each do |meth|
        define_method(meth) do |rpc_name, *params|
          received_calls << { rpc: rpc_name, params: params, context: current_context }
          if rpc_name == VALIDSIG_RPC
            return validsig
          end
          raise send_error, message if rpc_name == SEND_RPC

          raise "unexpected RPC #{rpc_name.inspect}"
        end
      end
    end.new
  end

  def no_wire_client
    Class.new do
      attr_reader :calls

      def initialize = @calls = []

      %i[call_rpc call_rpc_lines call_rpc_global_array].each do |meth|
        define_method(meth) do |rpc, *params|
          @calls << [ rpc, *params ]
          raise "RPC must not run for invalid Order.sign_and_release arguments"
        end
      end
    end.new
  end
end
