# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "set"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/order"

# rpms-rpc#456: Order.sign_and_release over ORWU VALIDSIG then ORWDX SEND
# (SEND^ORWDX → SEND1^ORWDX → EN^ORCSEND; pinned-build ORWDX.m:168-193).
#
# Broker formals SEND(ORWLST,DFN,ORNP,ORL,ES,ORWREC) (ORWDX.m:168-170):
# ES is the encrypted signature code; ORWREC(n)=ORIFN;Action^Signature Sts^
# Release Sts^Nature (comment ORWDX.m:170). CHKACT^ORWDXR validates
# ORWSIG/ORWREL/ORWNATR before EN^ORCSEND (ORWDXR.m:87-98). Reply piece 2
# is built at ORWDX.m:189-193 ("R" when released, "S" when ORWSIG'=2).
# Per-order status: :released (piece 2 exactly "RS"), :signed (exactly "S"),
# :rejected (nothing sent: bad args, blank signature, VALIDSIG not "1"),
# :unknown (SEND ran but outcome is not provable: bad/missing reply rows,
# ^E^ rows because EN^ORCSEND may have signed before ORERR, or SEND raised
# after the release loop — RpcError/RpcTimeoutError/post-loop M error).
# FrameTooLongError (nothing sent on the wire, client.rb #472) propagates
# like RpcNotAvailableError/RpcRefusedError — no :unknown rows.
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
    assert_equal 5, send[:params].length, "SEND(ORWLST,DFN,ORNP,ORL,ES,ORWREC) (ORWDX.m:168)"
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

  # --- reply parsing (ORWLST / ORWDX.m:189-193) --------------------------------

  def test_sign_and_release_released_only_when_piece_two_exactly_rs
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
    assert_match(/did not release/i, row[:reason])
    refute_match(/\bnot released\b/i, row[:reason])
    refute_equal :released, row[:status]
  end

  def test_sign_and_release_error_row_bare_orwerr_code_uses_generic_reason_without_code
    [ "#{ORDER_ONE}^E^1", "#{ORDER_ONE}^E^1^" ].each do |reply_row|
      RpmsRpc.reset!
      with_sign_release_wire(validsig: "1", send: [ reply_row ])

      results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

      row = results.fetch(0)
      assert_equal :unknown, row[:status], reply_row
      assert_match(/may already be signed/i, row[:reason], reply_row)
      assert_match(/check.*order|order.*before.*retr/i, row[:reason], reply_row)
      refute_match(/\A\d+; /, row[:reason], reply_row)
      refute_includes row[:reason], "1; the order may already be signed", reply_row
    end
  end

  def test_sign_and_release_error_row_parses_orwerr_text
    msg = "Synthetic order cannot be released"
    with_sign_release_wire(validsig: "1", send: [ "#{ORDER_ONE}^E^1^#{msg}" ])

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    row = results.fetch(0)
    assert_equal :unknown, row[:status]
    assert_includes row[:reason], msg
    assert_match(/signed/i, row[:reason])
    assert_match(/check.*order|order.*before.*retr/i, row[:reason])
    refute_equal :rejected, row[:status]
  end

  def test_sign_and_release_piece_two_r_er_xr_rejected_are_unknown_not_released
    [
      "#{ORDER_ONE}^R",
      "#{ORDER_ONE}^ER",
      "#{ORDER_ONE}^XR",
      "#{ORDER_ONE}^Rejected^x"
    ].each do |reply_row|
      RpmsRpc.reset!
      with_sign_release_wire(validsig: "1", send: [ reply_row ])

      results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

      assert_equal 1, results.length, reply_row
      assert_equal :unknown, results[0][:status], reply_row
      assert_unknown_outcome_reason(results[0][:reason])
      refute_equal :released, results[0][:status], reply_row
    end
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

  def test_sign_and_release_validsig_reply_zero_rejects_not_accepted_without_send
    with_sign_release_wire(validsig: "0", send: [ "#{ORDER_ONE}^RS" ])

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE, ORDER_TWO ], SIG_CODE)

    assert_empty rpc_calls.select { |c| c[:rpc] == SEND_RPC }
    assert_equal 2, results.length
    results.each do |row|
      assert_equal :rejected, row[:status]
      assert_match(/signature/i, row[:reason])
      assert_match(/not accepted/i, row[:reason])
    end
    refute_signature_leaked(results, SIG_CODE)
  end

  def test_sign_and_release_validsig_reply_not_one_or_zero_rejects_unconfirmed_without_send
    [ "", nil, "1 ", "-1^NOT AUTHORIZED" ].each do |bad|
      RpmsRpc.reset!
      with_sign_release_wire(validsig: bad, send: [ "#{ORDER_ONE}^RS" ])

      results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE, ORDER_TWO ], SIG_CODE)

      assert_empty rpc_calls.select { |c| c[:rpc] == SEND_RPC }, bad.inspect
      assert_equal 2, results.length
      results.each do |row|
        assert_equal :rejected, row[:status]
        assert_match(/signature/i, row[:reason])
        assert_match(/could not be confirmed/i, row[:reason])
        refute_match(/not accepted/i, row[:reason])
      end
      refute_signature_leaked(results, SIG_CODE)
    end
  end

  # ValidSignature.accepted? treats "yes" as true for the mapper; this call
  # does not. Only exactly "1" confirms the signature, so a look-alike never
  # reaches SEND.
  def test_sign_and_release_validsig_lookalikes_of_one_are_rejected_without_send
    [ "yes", "YES", "true", "1^", "01", "1.0" ].each do |bad|
      RpmsRpc.reset!
      with_sign_release_wire(validsig: bad, send: [ "#{ORDER_ONE}^RS" ])

      results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

      assert_empty rpc_calls.select { |c| c[:rpc] == SEND_RPC }, bad.inspect
      assert_equal [ :rejected ], results.map { |r| r[:status] }, bad.inspect
    end
  end

  # An ^E row means SEND ran and EN^ORCSEND may already have signed. A row with
  # no code or text after the E still carries that warning.
  def test_sign_and_release_bare_e_row_still_warns_the_order_may_be_signed
    with_sign_release_wire(validsig: "1", send: [ "#{ORDER_ONE}^E" ])

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    assert_equal [ :unknown ], results.map { |r| r[:status] }
    assert_match(/may already be signed/i, results.first[:reason])
  end

  # SEND^ORWDX never reads ES (pinned build ORWDX.m:168-193) and signs as the
  # SESSION user (ORCSEND.m:9); ORNP matters only to DC children. VALIDSIG
  # checks the session user's own code (ORWU.m:103-106). A provider_duz other
  # than the signed-on DUZ would have the order signed by someone else and
  # reported as the provider's.
  def test_sign_and_release_rejects_a_provider_duz_that_is_not_the_signed_on_session_user
    client = with_sign_release_wire(validsig: "1", send: [ "#{ORDER_ONE}^RS" ])
    client.define_singleton_method(:duz) { "302" }

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    assert_empty client.calls, "no RPC may run when the provider is not the session user"
    assert_equal [ :rejected ], results.map { |r| r[:status] }
    assert_match(/session user/i, results.first[:reason])
    refute_signature_leaked(results, SIG_CODE)
  end

  # Only the exact DUZ counts: a session DUZ that merely starts with the
  # provider's digits is a different user.
  def test_sign_and_release_rejects_a_session_duz_that_only_resembles_the_provider
    [ "301x", "3010", "0301", " 302" ].each do |session|
      client = with_sign_release_wire(validsig: "1", send: [ "#{ORDER_ONE}^RS" ])
      client.define_singleton_method(:duz) { session }

      results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

      assert_empty client.calls, session.inspect
      assert_equal [ :rejected ], results.map { |r| r[:status] }, session.inspect
    end
  end

  def test_sign_and_release_rejects_when_the_client_cannot_name_its_signed_on_user
    client = no_wire_client
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    assert_empty client.calls
    assert_equal [ :rejected ], results.map { |r| r[:status] }
    assert_match(/session user/i, results.first[:reason])
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

  def test_sign_and_release_non_array_order_ids_raises_argument_error_without_rpc
    client = no_wire_client
    RpmsRpc.configure { |c| c.client = client }

    [ ORDER_ONE, nil, 42, Set[ORDER_ONE] ].each do |bad_ids|
      client.calls.clear
      error = assert_raises(ArgumentError) do
        RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, bad_ids, SIG_CODE)
      end
      assert_match(/order_ids must be an Array/i, error.message, bad_ids.inspect)
      assert_empty client.calls, bad_ids.inspect
    end
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
    refute_signature_in_exception(error, SIG_CODE, wire_encrypted: wire_encrypted_es_from_calls)
  end

  def test_sign_and_release_send_frame_too_long_error_propagates
    assert_respond_to RpmsRpc::Order, :sign_and_release

    message = "parameter exceeds 999 byte lpack limit"
    RpmsRpc.reset!
    RpmsRpc.configure do |c|
      c.client = sign_release_error_client(
        validsig: "1",
        send_error: RpmsRpc::Client::FrameTooLongError,
        message: message
      )
    end

    error = assert_raises(RpmsRpc::Client::FrameTooLongError) do
      RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)
    end
    assert_equal message, error.message
    refute_signature_in_exception(error, SIG_CODE, wire_encrypted: wire_encrypted_es_from_calls)
  end

  def test_sign_and_release_send_lpack_too_long_subclass_propagates
    require "rpms_rpc/xwb_client"

    message = "999 byte lpack limit exceeded"
    RpmsRpc.reset!
    RpmsRpc.configure do |c|
      c.client = sign_release_error_client(
        validsig: "1",
        send_error: RpmsRpc::XwbClient::LpackTooLongError,
        message: message
      )
    end

    error = assert_raises(RpmsRpc::XwbClient::LpackTooLongError) do
      RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)
    end
    assert_equal message, error.message
    assert_kind_of RpmsRpc::Client::FrameTooLongError, error
    refute_signature_in_exception(error, SIG_CODE, wire_encrypted: wire_encrypted_es_from_calls)
  end

  def test_sign_and_release_oversized_dfn_lpack_too_long_before_send_propagates
    require "rpms_rpc/xwb_client"

    sock = Class.new do
      attr_reader :writes

      def initialize = @writes = []

      def write(s)
        @writes << s.b
        s.bytesize
      end

      def recv(_n) = ""

      def flush; end

      def close; end

      def closed? = false

      def setsockopt(*); end
    end.new

    cli = Class.new(RpmsRpc::XwbClient) do
      define_method(:received_calls) { @calls ||= [] }
      define_method(:calls) { received_calls }

      define_method(:call_rpc) do |name, *params|
        received_calls << { rpc: name, params: params }
        return RpmsRpc::Reply.from_wire([ "1" ]) if name == VALIDSIG_RPC

        super(name, *params)
      end
    end.new
    cli.set_authenticated(PROVIDER_DUZ)
    cli.instance_variable_set(:@socket, sock)
    cli.instance_variable_set(:@connected, true)
    RpmsRpc.reset!
    RpmsRpc.configure { |c| c.client = cli }

    bytes_before = sock.writes.sum(&:bytesize)
    error = assert_raises(RpmsRpc::XwbClient::LpackTooLongError) do
      RpmsRpc::Order.sign_and_release("1" * 1000, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)
    end
    assert_kind_of RpmsRpc::Client::FrameTooLongError, error
    refute_signature_in_exception(error, SIG_CODE, wire_encrypted: wire_encrypted_es_from_calls)
    assert_equal bytes_before, sock.writes.sum(&:bytesize),
                 "SEND must not write after lpack refusal (nothing sent for that RPC)"
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
    refute_signature_in_exception(error, SIG_CODE, wire_encrypted: wire_encrypted_es_from_calls)
  end

  def test_sign_and_release_send_rpc_error_returns_unknown_rows_not_exception
    assert_respond_to RpmsRpc::Order, :sign_and_release

    message = "M  ERROR=synthetic fault in EN^ORCSEND"
    RpmsRpc.reset!
    RpmsRpc.configure { |c| c.client = sign_release_error_client(validsig: "1", send_error: RpmsRpc::Client::RpcError, message: message) }

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE, ORDER_TWO ], SIG_CODE)

    assert_send_error_unknown_results(
      results,
      [ ORDER_ONE, ORDER_TWO ],
      RpmsRpc::Client::RpcError,
      forbidden_message: message
    )
    assert_equal 1, rpc_calls.count { |c| c[:rpc] == VALIDSIG_RPC }
    assert_equal 1, rpc_calls.count { |c| c[:rpc] == SEND_RPC }
  end

  def test_sign_and_release_send_rpc_m_error_after_release_loop_returns_unknown_rows
    message = "M  ERROR=<UNDEFINED>BTS+3^ORMBLD"
    RpmsRpc.reset!
    RpmsRpc.configure do |c|
      c.client = sign_release_error_client(validsig: "1", send_error: RpmsRpc::Client::RpcMError, message: message)
    end

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE, ORDER_TWO ], SIG_CODE)

    assert_send_error_unknown_results(
      results,
      [ ORDER_ONE, ORDER_TWO ],
      RpmsRpc::Client::RpcMError,
      forbidden_message: message
    )
  end

  def test_sign_and_release_send_rpc_timeout_error_returns_unknown_rows
    message = "RPC read timed out after 30s"
    RpmsRpc.reset!
    RpmsRpc.configure do |c|
      c.client = sign_release_error_client(
        validsig: "1",
        send_error: RpmsRpc::Client::RpcTimeoutError,
        message: message
      )
    end

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    assert_send_error_unknown_results(
      results,
      [ ORDER_ONE ],
      RpmsRpc::Client::RpcTimeoutError,
      forbidden_message: message
    )
  end

  def test_sign_and_release_send_connection_error_returns_unknown_rows
    message = "Connection lost - stream closed"
    RpmsRpc.reset!
    RpmsRpc.configure do |c|
      c.client = sign_release_error_client(
        validsig: "1",
        send_error: RpmsRpc::Client::ConnectionError,
        message: message
      )
    end

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    assert_send_error_unknown_results(
      results,
      [ ORDER_ONE ],
      RpmsRpc::Client::ConnectionError,
      forbidden_message: message
    )
  end

  def test_sign_and_release_send_connection_not_connected_returns_unknown_rows
    message = "Not connected"
    RpmsRpc.reset!
    RpmsRpc.configure do |c|
      c.client = sign_release_error_client(
        validsig: "1",
        send_error: RpmsRpc::Client::ConnectionError,
        message: message
      )
    end

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    assert_send_error_unknown_results(
      results,
      [ ORDER_ONE ],
      RpmsRpc::Client::ConnectionError,
      forbidden_message: message
    )
  end

  def test_sign_and_release_send_parse_error_returns_unknown_rows
    message = "unexpected broker payload"
    RpmsRpc.reset!
    RpmsRpc.configure do |c|
      c.client = sign_release_error_client(
        validsig: "1",
        send_error: RpmsRpc::Client::ParseError,
        message: message
      )
    end

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    assert_send_error_unknown_results(
      results,
      [ ORDER_ONE ],
      RpmsRpc::Client::ParseError,
      forbidden_message: message
    )
  end

  def test_sign_and_release_send_non_rpms_error_returns_unknown_rows_class_only
    message = "bad param #{SIG_CODE}"
    RpmsRpc.reset!
    RpmsRpc.configure do |c|
      c.client = sign_release_send_raises_client { ArgumentError.new(message) }
    end

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    assert_send_error_unknown_results(
      results,
      [ ORDER_ONE ],
      ArgumentError,
      forbidden_message: message
    )
  end

  def test_sign_and_release_same_error_class_validsig_propagates_send_returns_unknown_rows
    error_class = RpmsRpc::Client::RpcTimeoutError
    message = "RPC read timed out after 30s"

    RpmsRpc.reset!
    RpmsRpc.configure { |c| c.client = sign_release_validsig_raises_client { error_class.new(message) } }

    error = assert_raises(error_class) do
      RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE, ORDER_TWO ], SIG_CODE)
    end
    assert_equal message, error.message
    assert_empty rpc_calls.select { |c| c[:rpc] == SEND_RPC }

    RpmsRpc.reset!
    RpmsRpc.configure do |c|
      c.client = sign_release_error_client(validsig: "1", send_error: error_class, message: message)
    end

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE, ORDER_TWO ], SIG_CODE)

    assert_send_error_unknown_results(
      results,
      [ ORDER_ONE, ORDER_TWO ],
      error_class,
      forbidden_message: message
    )
    assert_equal 1, rpc_calls.count { |c| c[:rpc] == VALIDSIG_RPC }
    assert_equal 1, rpc_calls.count { |c| c[:rpc] == SEND_RPC }
  end

  def test_sign_and_release_send_error_after_validsig_does_not_leak_signature
    assert_respond_to RpmsRpc::Order, :sign_and_release

    message = "M  ERROR=synthetic fault after VALIDSIG"
    RpmsRpc.reset!
    RpmsRpc.configure do |c|
      c.client = sign_release_error_client(validsig: "1", send_error: RpmsRpc::Client::RpcError, message: message)
    end

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    assert_equal 1, RpmsRpc.client.received_calls.count { |c| c[:rpc] == VALIDSIG_RPC }
    assert_send_error_unknown_results(
      results,
      [ ORDER_ONE ],
      RpmsRpc::Client::RpcError,
      forbidden_message: message
    )
  end

  def test_sign_and_release_send_broker_error_redacts_plaintext_and_wire_ciphertext_on_propagate
    [
      RpmsRpc::Client::RpcNotAvailableError,
      RpmsRpc::Client::RpcRefusedError
    ].each do |error_class|
      RpmsRpc.reset!
      client = sign_release_send_raises_client do |params|
        encrypted = params[3].to_s
        plaintext = RpmsRpc::XwbCipher.decrypt(encrypted)
        error_class.new("boom ES=#{encrypted} sig=#{plaintext}")
      end
      RpmsRpc.configure { |c| c.client = client }

      error = assert_raises(error_class) do
        RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)
      end

      wire = wire_encrypted_es_from_calls
      refute_nil wire
      refute_includes error.message, SIG_CODE
      refute_includes error.message, wire
      refute_signature_in_exception(error, SIG_CODE, wire_encrypted: wire)
    end
  end

  def test_sign_and_release_send_rpc_error_with_secrets_in_exception_returns_unknown_rows_without_leak
    RpmsRpc.reset!
    client = sign_release_send_raises_client do |params|
      encrypted = params[3].to_s
      plaintext = RpmsRpc::XwbCipher.decrypt(encrypted)
      RpmsRpc::Client::RpcError.new("boom ES=#{encrypted} sig=#{plaintext}")
    end
    RpmsRpc.configure { |c| c.client = client }

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    assert_send_error_unknown_results(results, [ ORDER_ONE ], RpmsRpc::Client::RpcError, forbidden_message: SIG_CODE)
  end

  def test_sign_and_release_validsig_rpc_error_clean_message_dirty_cause_redacts_secrets
    RpmsRpc.reset!
    client = sign_release_validsig_raises_client do |params|
      encrypted = params[0].to_s
      plaintext = RpmsRpc::XwbCipher.decrypt(encrypted)
      begin
        raise IOError, "write failed for param #{encrypted} / #{plaintext}"
      rescue IOError => cause
        raise RpmsRpc::Client::RpcError, "broker failed", cause: cause
      end
    end
    RpmsRpc.configure { |c| c.client = client }

    error = assert_raises(RpmsRpc::Client::RpcError) do
      RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)
    end

    assert_equal "broker failed", error.message
    refute_signature_in_exception(error, SIG_CODE, wire_encrypted: wire_encrypted_es_from_calls)
    assert_empty rpc_calls.select { |c| c[:rpc] == SEND_RPC }
  end

  def test_sign_and_release_validsig_frozen_rpms_error_redacts_without_frozen_error
    shared = RpmsRpc::Error.new("bad sig=#{SIG_CODE}")
    shared.freeze
    RpmsRpc.reset!
    RpmsRpc.configure do |c|
      c.client = sign_release_validsig_raises_client { shared }
    end

    error = assert_raises(RpmsRpc::Error) do
      RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)
    end

    refute_instance_of FrozenError, error
    refute_signature_in_exception(error, SIG_CODE, wire_encrypted: wire_encrypted_es_from_calls)
    assert_includes shared.message, SIG_CODE, "original client exception must not be mutated"
    assert_empty rpc_calls.select { |c| c[:rpc] == SEND_RPC }
  end

  def test_sign_and_release_validsig_non_rpms_error_with_secret_wraps_redacted_rpms_error
    RpmsRpc.reset!
    client = sign_release_validsig_raises_client do |_params|
      ArgumentError.new("bad param #{SIG_CODE}")
    end
    RpmsRpc.configure { |c| c.client = client }

    error = assert_raises(RpmsRpc::Error) do
      RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)
    end

    refute_instance_of ArgumentError, error
    refute_includes error.message, SIG_CODE
    refute_signature_in_exception(error, SIG_CODE, wire_encrypted: wire_encrypted_es_from_calls)
    assert_empty rpc_calls.select { |c| c[:rpc] == SEND_RPC }
  end

  def test_sign_and_release_validsig_rpc_error_redacts_inspect_escaped_wire_ciphertext
    RpmsRpc.reset!
    client = sign_release_validsig_raises_client do |params|
      RpmsRpc::Client::RpcError.new("params=#{params.inspect}")
    end
    RpmsRpc.configure { |c| c.client = client }

    error = assert_raises(RpmsRpc::Client::RpcError) do
      RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)
    end

    wire = wire_encrypted_es_from_calls
    refute_nil wire
    refute_signature_in_exception(error, SIG_CODE, wire_encrypted: wire)
    assert_empty rpc_calls.select { |c| c[:rpc] == SEND_RPC }
  end

  def test_sign_and_release_validsig_broker_error_redacts_plaintext_and_wire_ciphertext
    [
      RpmsRpc::Client::RpcError,
      RpmsRpc::Client::RpcNotAvailableError,
      RpmsRpc::Client::RpcRefusedError
    ].each do |error_class|
      RpmsRpc.reset!
      client = sign_release_validsig_raises_client do |params|
        encrypted = params[0].to_s
        plaintext = RpmsRpc::XwbCipher.decrypt(encrypted)
        error_class.new("boom ES=#{encrypted} sig=#{plaintext}")
      end
      RpmsRpc.configure { |c| c.client = client }

      error = assert_raises(error_class) do
        RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)
      end

      wire = wire_encrypted_es_from_calls
      refute_nil wire
      refute_includes error.message, SIG_CODE
      refute_includes error.message, wire
      refute_signature_in_exception(error, SIG_CODE, wire_encrypted: wire)
      assert_empty rpc_calls.select { |c| c[:rpc] == SEND_RPC }
    end
  end

  def test_sign_and_release_validsig_error_does_not_mutate_original_client_exception
    shared = RpmsRpc::Error.new("cached failure for #{SIG_CODE}")
    original_message = shared.message.dup
    RpmsRpc.reset!
    RpmsRpc.configure { |c| c.client = sign_release_validsig_raises_client { shared } }

    assert_raises(RpmsRpc::Error) do
      RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)
    end

    assert_equal original_message, shared.message
    assert_includes shared.message, SIG_CODE
    assert_empty rpc_calls.select { |c| c[:rpc] == SEND_RPC }
  end

  def test_sign_and_release_rpc_not_available_on_validsig_propagates
    assert_respond_to RpmsRpc::Order, :sign_and_release

    message = "3 Unknown remote procedure: ORWU VALIDSIG"
    RpmsRpc.reset!
    client = Class.new do
      define_method(:duz) { PROVIDER_DUZ }
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

  def assert_send_broker_failure_unknown_reason(reason, error_class, forbidden_message: nil)
    assert reason, "expected reason for SEND broker failure :unknown"
    assert_match(/release request may have been sent but failed/i, reason)
    refute_match(/release request was sent but failed/i, reason)
    refute_match(/\bwas sent\b/i, reason)
    assert_match(/check.*order|order.*before.*retr/i, reason)
    short = error_class.name.split("::").last
    assert_match(/\b#{Regexp.escape(short)}\b/, reason)
    refute_includes reason, forbidden_message if forbidden_message && !forbidden_message.empty?
  end

  def assert_send_error_unknown_results(results, order_ids, error_class, forbidden_message: nil, plaintext: SIG_CODE)
    assert_equal order_ids.length, results.length
    order_ids.each do |oid|
      row = results.find { |r| r[:order_id] == oid }
      refute_nil row, "missing row for #{oid}"
      assert_equal :unknown, row[:status]
      assert_send_broker_failure_unknown_reason(row[:reason], error_class, forbidden_message: forbidden_message)
    end
    refute_signature_leaked(results, plaintext)
  end

  def wire_encrypted_es_from_calls
    send = send_call
    wire = send&.dig(:params, 3)
    return wire.to_s if wire && !wire.to_s.empty?

    valid = rpc_calls.find { |c| c[:rpc] == VALIDSIG_RPC }
    valid&.dig(:params, 0).to_s
  end

  def refute_signature_in_exception(error, plaintext, wire_encrypted:)
    wire_encrypted = wire_encrypted.to_s
    inspect_escaped_wire = wire_encrypted.inspect[1..-2]

    ex = error
    while ex
      refute_includes ex.message, plaintext.to_s
      refute_includes ex.message, wire_encrypted unless wire_encrypted.empty?
      unless inspect_escaped_wire.nil? || inspect_escaped_wire.empty?
        refute_includes ex.message, inspect_escaped_wire
      end
      if ex.respond_to?(:full_message)
        full = ex.full_message
        refute_includes full, plaintext.to_s
        refute_includes full, wire_encrypted unless wire_encrypted.empty?
        unless inspect_escaped_wire.nil? || inspect_escaped_wire.empty?
          refute_includes full, inspect_escaped_wire
        end
      end
      ex = ex.cause
    end
  end

  def refute_signature_leaked(value, plaintext, wire_encrypted: nil)
    wire_encrypted = (wire_encrypted || wire_encrypted_es_from_calls).to_s
    inspect_escaped_wire = wire_encrypted.inspect[1..-2]
    walk = []
    case value
    when Array
      value.each { |v| walk.concat(collect_strings(v)) }
    else
      walk = collect_strings(value)
    end
    blob = walk.join("\0")
    refute_includes blob, plaintext.to_s, "plaintext signature must not appear in results"
    unless wire_encrypted.empty?
      refute_includes blob, wire_encrypted, "encrypted signature must not appear in results"
    end
    unless inspect_escaped_wire.nil? || inspect_escaped_wire.empty?
      refute_includes blob, inspect_escaped_wire, "inspect-escaped ciphertext must not appear in results"
    end
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
    def duz = PROVIDER_DUZ

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

  def sign_release_send_raises_client(&on_send)
    Class.new do
      define_method(:received_calls) { @calls ||= [] }
      define_method(:current_context) { nil }
      define_method(:duz) { PROVIDER_DUZ }

      %i[call_rpc call_rpc_lines call_rpc_global_array].each do |meth|
        define_method(meth) do |rpc_name, *params|
          received_calls << { rpc: rpc_name, params: params, context: current_context }
          return "1" if rpc_name == VALIDSIG_RPC

          if rpc_name == SEND_RPC
            exc = on_send.call(params)
            raise exc
          end

          raise "unexpected RPC #{rpc_name.inspect}"
        end
      end
    end.new
  end

  def sign_release_validsig_raises_client(&on_validsig)
    Class.new do
      define_method(:received_calls) { @calls ||= [] }
      define_method(:current_context) { nil }
      define_method(:duz) { PROVIDER_DUZ }

      %i[call_rpc call_rpc_lines call_rpc_global_array].each do |meth|
        define_method(meth) do |rpc_name, *params|
          received_calls << { rpc: rpc_name, params: params, context: current_context }
          if rpc_name == VALIDSIG_RPC
            exc = on_validsig.call(params)
            raise exc
          end

          raise "unexpected RPC #{rpc_name.inspect}" if rpc_name == SEND_RPC

          raise "unexpected RPC #{rpc_name.inspect}"
        end
      end
    end.new
  end

  def sign_release_error_client(validsig:, send_error:, message:)
    Class.new do
      define_method(:received_calls) { @calls ||= [] }
      define_method(:current_context) { nil }
      define_method(:duz) { PROVIDER_DUZ }

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
