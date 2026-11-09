# frozen_string_literal: true

require "monitor"
require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/order"
require_relative "../captured_replies"

# Gate H1: Order.sign_and_release must hold RpmsRpc.synchronize_wire across the
# session-user check, ORWU VALIDSIG, and ORWDX SEND so a concurrent sign-on
# cannot rebind DUZ between VALIDSIG and SEND.
#
# The concurrency tests drive a hand-built client that records the lock it
# holds; their replies are VALIDSIG's "1" and a released SEND row. The
# sign-and-release tests at the end replay the build's own VALIDSIG and SEND
# replies (test/fixtures/captured_replies/order-write.yml) through CiaClient.
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

  # F1: sign_and_release resolves RpmsRpc.client once for RPCs but
  # RpmsRpc.synchronize_wire resolves it again for the lock. After a
  # reconfigure, RPCs run on client A while the monitor held is B's.
  def test_sign_and_release_holds_resolved_client_wire_lock_when_global_client_is_reconfigured_before_synchronize_wire
    original_client = RpmsRpc.method(:client)
    client_a = wire_lock_sign_release_client(per_call_lock: false)
    client_a.duz = PROVIDER_DUZ
    client_b = wire_lock_sign_release_client(per_call_lock: false)
    client_b.duz = PROVIDER_DUZ

    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client_a }

    resolver_reads = 0
    RpmsRpc.singleton_class.define_method(:client) do
      resolver_reads += 1
      if resolver_reads == 1
        client_a
      else
        RpmsRpc.configuration.client = client_b
        client_b
      end
    end

    peer_entered_a_lock = [ false ]
    peer_on_a = nil
    client_a.after_validsig_hook = lambda do |_cli|
      peer_on_a = Thread.new do
        client_a.synchronize_wire { peer_entered_a_lock[0] = true }
      end
      INTERLEAVE_SPIN_CAP.times do
        break if peer_on_a.status == "sleep" || peer_entered_a_lock[0]

        Thread.pass
      end
      refute(
        peer_entered_a_lock[0],
        "a peer must not acquire client A's wire lock during VALIDSIG..SEND; " \
        "doing so means the sequence is not held on the client that owns the RPCs"
      )
    end

    begin
      results = RpmsRpc::Order.sign_and_release(
        DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE
      )

      refute_nil peer_on_a
      peer_on_a.kill
      assert peer_on_a.join(THREAD_JOIN_TIMEOUT)

      # Factory-Spec-Amendment: the contract is that the lock is client A's own, not
      # that the module lock re-reads RpmsRpc.client. The fix takes the lock on the
      # client resolved at entry, so it reads once; the old code read twice. The
      # assertions below carry the contract and are unchanged (#456).
      assert_operator resolver_reads, :>=, 1
      assert_nil client_a.lock_violation,
                 "VALIDSIG and SEND must run under client A's wire lock, not a re-resolved client's"
      assert_equal 2, client_a.rpc_log.length, "RPCs must still use the client resolved at entry"
      assert_empty client_b.rpc_log, "re-resolved client B must not receive VALIDSIG or SEND"

      row = results.fetch(0)
      assert_equal :released, row[:status]
    ensure
      RpmsRpc.singleton_class.define_method(:client, original_client)
    end
  end

  # A client with no #synchronize_wire takes the module wire lock, the same
  # fallback RpmsRpc.synchronize_wire uses, without re-reading RpmsRpc.client.
  class BareWireClient
    attr_reader :rpc_names, :module_lock_owned

    def initialize
      @rpc_names = []
      @module_lock_owned = []
    end

    def duz = PROVIDER_DUZ

    def call_rpc(rpc_name, *_params)
      @rpc_names << rpc_name
      @module_lock_owned << RpmsRpc::MODULE_WIRE_LOCK.mon_owned?
      rpc_name == VALIDSIG_RPC ? "1" : [ "#{ORDER_ONE}^RS" ]
    end
  end

  def test_sign_and_release_holds_the_module_wire_lock_for_a_client_without_synchronize_wire
    client = BareWireClient.new
    refute_respond_to client, :synchronize_wire
    RpmsRpc.configure { |cfg| cfg.client = client }

    results = RpmsRpc::Order.sign_and_release(DFN, PROVIDER_DUZ, LOCATION, [ ORDER_ONE ], SIG_CODE)

    assert_equal [ VALIDSIG_RPC, SEND_RPC ], client.rpc_names
    assert_equal [ true, true ], client.module_lock_owned,
                 "VALIDSIG and SEND must both run under the module wire lock"
    refute RpmsRpc::MODULE_WIRE_LOCK.mon_owned?, "the module wire lock must be released afterwards"
    assert_equal :released, results.fetch(0)[:status]
  end

  # The build's replies, as PROFILE,MD (DUZ 206) signed the order saved on
  # DFN 990034 at hospital location 7.
  SLUG = "order-write"
  SENT = CapturedReplies.file(SLUG).fetch("captures").find { |c| c["name"] == "send" }.fetch("inputs")
  CAPTURED_ORDER = SENT.last.first.split("^").first

  def replay_sign(validsig, *sends, duz: "206")
    script = { VALIDSIG_RPC => [ CapturedReplies.raw(SLUG, validsig) ] }
    script[SEND_RPC] = sends.map { |name| CapturedReplies.raw(SLUG, name) } unless sends.empty?
    @replay = CapturedReplies::ReplayCiaClient.new(script).signed_on_as(duz)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = @replay }
  end

  def sign(code = "123456") = RpmsRpc::Order.sign_and_release(SENT[0], SENT[1], SENT[2], [ CAPTURED_ORDER ], code)

  def test_sign_and_release_validsig_then_send_releases_the_order
    replay_sign("validsig", "send")

    results = sign

    assert_equal [ VALIDSIG_RPC, SEND_RPC ], @replay.rpcs_called
    assert_equal [ { order_id: CAPTURED_ORDER, status: :released } ], results.map { |r| r.slice(:order_id, :status) }
    sent = @replay.calls.last[:params]
    assert_equal SENT.values_at(0, 1, 2, 4), sent.values_at(0, 1, 2, 4), "DFN, provider, location and ORWREC as captured"
    assert_equal @replay.calls.first[:params].first, sent[3], "SEND carries the ciphertext VALIDSIG checked"
  end

  # The same order again: SEND answers "S", signed as requested; not a release.
  def test_sign_and_release_of_a_released_order_is_not_reported_released
    replay_sign("validsig", "send_again")

    results = sign

    refute_equal :released, results.first[:status]
  end

  def test_sign_and_release_wrong_code_is_rejected_without_send
    replay_sign("validsig_wrong")

    results = sign("999999")

    assert_equal [ VALIDSIG_RPC ], @replay.rpcs_called
    assert_equal [ :rejected ], results.map { |r| r[:status] }
    assert_equal RpmsRpc::Order::SIGN_RELEASE_REFUSED, results.first[:reason]
  end

  def test_sign_and_release_rejects_a_provider_who_is_not_the_session_user_without_rpc
    replay_sign("validsig", "send", duz: "302")

    results = sign

    assert_empty @replay.calls
    assert_equal [ :rejected ], results.map { |r| r[:status] }
    assert_match(/session user/i, results.first[:reason])
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
