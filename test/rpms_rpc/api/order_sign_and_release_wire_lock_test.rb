# frozen_string_literal: true

require "monitor"
require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/authentication"
require "rpms_rpc/api/order"

# Gate H1: Order.sign_and_release must hold RpmsRpc.synchronize_wire across the
# session-user check, ORWU VALIDSIG, and ORWDX SEND so a concurrent sign-on
# cannot rebind DUZ between VALIDSIG and SEND.
class OrderSignAndReleaseWireLockTest < Minitest::Test
  SEND_RPC = "ORWDX SEND"
  VALIDSIG_RPC = "ORWU VALIDSIG"

  DFN = "8791"
  PROVIDER_DUZ = "301"
  LOCATION = "349"
  SIG_CODE = "synthetic-es-code"
  ORDER_ONE = "10;1"
  ORWREC_ROW = "1^1^E"

  INTERLEAVE_SPIN_CAP = 100_000
  THREAD_JOIN_TIMEOUT = 5

  def teardown
    RpmsRpc.reset!
  end

  def test_sign_and_release_validsig_send_complete_before_concurrent_sign_on_rebinds_duz
    client = wire_lock_sign_release_client(per_call_lock: false)
    client.duz = PROVIDER_DUZ
    b_thread = nil
    client.after_validsig_hook = lambda do |_cli|
      b_thread = Thread.new do
        RpmsRpc.synchronize_wire { client.set_authenticated("999") }
      end
      INTERLEAVE_SPIN_CAP.times do
        break if b_thread.status == "sleep"

        Thread.pass
      end
      assert_equal(
        "sleep",
        b_thread.status,
        "concurrent sign-on must block on wire lock during VALIDSIG; finishing here means DUZ rebinding before SEND"
      )
    end

    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }

    results = RpmsRpc::Order.sign_and_release(
      DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE
    )

    refute_nil b_thread
    assert b_thread.join(THREAD_JOIN_TIMEOUT), "concurrent sign-on thread did not finish"

    send_duz = client.rpc_log.find { |e| e[:rpc] == SEND_RPC }&.fetch(:duz)
    assert_equal PROVIDER_DUZ, send_duz,
                 "ORWDX SEND must run while session DUZ is still #{PROVIDER_DUZ} (checked by VALIDSIG), not 999"

    rpc_names = client.rpc_log.map { |e| e[:rpc] }
    rebind_idx = client.events.index { |ev| ev.first == :rebind }
    refute_nil rebind_idx, "expected a logged rebind from concurrent sign-on"
    validsig_idx = rpc_names.index(VALIDSIG_RPC)
    send_idx = rpc_names.index(SEND_RPC)
    refute_nil validsig_idx
    refute_nil send_idx
    assert_operator validsig_idx, :<, send_idx, "VALIDSIG before SEND"
    assert_operator send_idx, :<, rebind_idx, "SEND before concurrent rebind to 999"

    row = results.fetch(0)
    assert_equal ORDER_ONE, row[:order_id]
    assert_equal :released, row[:status]
  end

  def test_sign_and_release_holds_wire_lock_from_before_validsig_through_send
    client = wire_lock_sign_release_client(per_call_lock: false)
    client.duz = PROVIDER_DUZ

    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }

    RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    assert_nil client.lock_violation,
               "expected outer wire lock during RPCs, saw violation at #{client.lock_violation.inspect}"

    enters = client.events.each_index.select { |i| client.events[i] == [ :lock_enter ] }
    exits = client.events.each_index.select { |i| client.events[i] == [ :lock_exit ] }
    refute_empty enters, "expected at least one :lock_enter from RpmsRpc.synchronize_wire"
    refute_empty exits, "expected at least one :lock_exit"

    outer_enter = enters.first
    outer_exit = exits.last
    rpc_indices = client.events.each_index.select { |i| client.events[i].first == :rpc }
    refute_empty rpc_indices

    assert_operator outer_enter, :<, rpc_indices.first,
                    ":lock_enter must precede the first RPC (session check + VALIDSIG + SEND under one lock)"
    assert_operator rpc_indices.last, :<, outer_exit,
                    ":lock_exit must follow SEND"

    rpc_events = client.events.select { |ev| ev.first == :rpc }
    assert_equal [ VALIDSIG_RPC, SEND_RPC ], rpc_events.map { |_, name, _| name }
  end

  def test_sign_and_release_session_user_mismatch_sends_no_rpc_under_wire_lock_client
    client = wire_lock_sign_release_client(per_call_lock: false)
    client.duz = "302"

    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }

    results = RpmsRpc::Order.sign_and_release(
      DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE
    )

    assert_empty client.rpc_log, "provider #{PROVIDER_DUZ} != session DUZ 302: no RPC"
    assert_equal [ :rejected ], results.map { |r| r[:status] }
    assert_match(/session user/i, results.first[:reason])
  end

  def test_sign_and_release_validsig_and_send_use_the_same_configured_client
    client = wire_lock_sign_release_client(per_call_lock: false)
    client.duz = PROVIDER_DUZ

    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }

    RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    assert_nil client.lock_violation
    assert_equal 2, client.rpc_log.length
    ids = client.rpc_log.map { |e| e[:client_id] }.uniq
    assert_equal 1, ids.length, "VALIDSIG and SEND must hit the same client object"
    assert_equal client.object_id, ids.first
  end

  def test_mock_client_exposes_session_duz_mutators
    mock = RpmsRpc::MockClient.new

    assert_respond_to mock, :duz
    assert_respond_to mock, :set_authenticated
    assert_respond_to mock, :clear_authenticated

    assert_nil mock.duz
    mock.set_authenticated("301")
    assert_equal "301", mock.duz
    mock.clear_authenticated
    assert_nil mock.duz
  end

  def test_mock_sign_and_release_reaches_validsig_when_session_duz_matches_provider
    mock = RpmsRpc.mock!
    mock.set_authenticated(PROVIDER_DUZ)

    results = RpmsRpc::Order.sign_and_release(
      DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE
    )

    refute_match(/not the signed-on session user/i, results.first[:reason].to_s)
    assert(
      mock.received_calls.any? { |c| c[:rpc] == VALIDSIG_RPC },
      "expected ORWU VALIDSIG once session DUZ matches provider"
    )
  end

  def test_mock_sign_and_release_rejects_session_user_mismatch_without_rpc
    mock = RpmsRpc.mock!
    mock.set_authenticated("302")

    results = RpmsRpc::Order.sign_and_release(
      DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE
    )

    assert_empty mock.received_calls
    assert_equal [ :rejected ], results.map { |r| r[:status] }
    assert_match(/session user/i, results.first[:reason])
  end

  def test_mock_authentication_sign_on_sets_client_duz
    RpmsRpc::Authentication.clear_cache!
    mock = RpmsRpc.mock! do |m|
      m.seed_scalar(:signon_setup, "", "OK")
      m.seed_user(
        "301",
        credentials: "ACCESS123;VERIFY123",
        name: "PROVIDER,TEST",
        role: :provider
      )
    end

    result = RpmsRpc::Authentication.authenticate(
      access_code: "ACCESS123", verify_code: "VERIFY123"
    )

    assert result[:success]
    assert_equal "301", mock.duz.to_s
  ensure
    RpmsRpc::Authentication.clear_cache!
  end

  private

  def wire_lock_sign_release_client(per_call_lock:)
    code = SIG_CODE
    wire_lock = Monitor.new
    events = []
    rpc_log = []
    duz_holder = [ PROVIDER_DUZ ]
    after_validsig_hook = [ nil ]
    lock_violation = [ nil ]

    client = Object.new
    client.define_singleton_method(:wire_lock) { wire_lock }
    client.define_singleton_method(:events) { events }
    client.define_singleton_method(:rpc_log) { rpc_log }
    client.define_singleton_method(:lock_violation) { lock_violation[0] }
    client.define_singleton_method(:duz) { duz_holder.first }
    client.define_singleton_method(:duz=) { |v| duz_holder[0] = v.to_s }
    client.define_singleton_method(:after_validsig_hook=) { |hook| after_validsig_hook[0] = hook }
    client.define_singleton_method(:current_context) { nil }

    client.define_singleton_method(:set_authenticated) do |new_duz|
      events << [ :rebind, new_duz.to_s ]
      duz_holder[0] = new_duz.to_s
    end

    client.define_singleton_method(:clear_authenticated) do
      duz_holder[0] = nil
    end

    client.define_singleton_method(:synchronize_wire) do |&block|
      events << [ :lock_enter ]
      wire_lock.synchronize { block.call }
      events << [ :lock_exit ]
    end

    dispatch = lambda do |rpc_name, *params|
      log_rpc = lambda do
        rpc_log << { rpc: rpc_name, duz: duz_holder.first, client_id: client.object_id }
        events << [ :rpc, rpc_name, duz_holder.first ]
        case rpc_name
        when VALIDSIG_RPC
          wire = params.first.to_s
          decrypted = RpmsRpc::XwbCipher.decrypt(wire)
          reply = (decrypted == code ? "1" : "0")
          hook = after_validsig_hook[0]
          hook&.call(client)
          reply
        when SEND_RPC
          [ "#{ORDER_ONE}^RS" ]
        else
          raise "unexpected RPC #{rpc_name.inspect}"
        end
      end

      if per_call_lock
        wire_lock.synchronize { log_rpc.call }
      else
        lock_violation[0] ||= rpc_name unless wire_lock.mon_owned?
        log_rpc.call
      end
    end

    %i[call_rpc call_rpc_lines call_rpc_global_array].each do |meth|
      client.define_singleton_method(meth, &dispatch)
    end

    client
  end
end
