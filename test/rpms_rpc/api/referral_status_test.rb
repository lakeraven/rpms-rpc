# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/referral"

# Referral.record_status files a checked STATUS OF REFERRAL (#90001 .15)
# through BMC REFERRAL STATUS UPDATE, UPDTSTRF^BMCRPC3(RSLT,REFIEN,STATUS)
# (rpms-rpc#722). The routine files any string (FILE^DIE without the E flag),
# and it does not NEW FDA or ERR1: FILE^DIE keeps the FDA when it fails
# (DIEF.m:24), so after one failed update in a broker session every later
# one re-files every queued write and answers "~`0^...". A "1" reply is
# decided by the read-back of .15; a "~`0" reply is :session_poisoned
# whatever .15 reads. The entry is locked (DDR LOCK/UNLOCK NODE on
# ^BMCREF(ien)) from before the first read until after the read-back, and a
# read that lacks the .15 row is unreadable, not empty. Every reply here is seeded, so these tests prove the
# frame and the guards, not the build:
# test/live/referral_status_live_test.rb is the live proof.
class ReferralStatusTest < Minitest::Test
  IEN = "7"
  SIGN_ON_CONTEXT = "CIAV VUECENTRIC"
  STATUS_RPC = "BMC REFERRAL STATUS UPDATE"
  LOCK_RPC = "DDR LOCK/UNLOCK NODE"
  GETS_RPC = "DDR GETS ENTRY DATA"
  NODE = "^BMCREF(#{IEN})"
  LOCK = RpmsRpc::DdrFileman.lock_param(node: NODE, timeout: 5).freeze
  UNLOCK = RpmsRpc::DdrFileman.unlock_param(node: NODE).freeze
  GETS = RpmsRpc::DdrFileman.gets_entry_param(file: "90001", iens: "#{IEN},", fields: ".15", flags: "I").freeze
  # Read-backs that cannot say what .15 holds: no reply, an error, no .15 row.
  UNREADABLE = { "no reply" => "", "an error" => "[ERROR]\n[BEGIN_diERRORS]\n601^The entry does not exist.\n[END_diERRORS]",
                 "no .15 row" => "[Data]", "another field's row only" => "[Data]\n90001^#{IEN},^.01^3261114" }.freeze
  STALE = "~`0^Error updating referral:The entry does not exist."

  def teardown
    RpmsRpc.reset!
  end

  def test_a_status_change_sends_two_parameters_under_bmcrpc_and_reads_back
    mock = seeded_mock(before: "A", after: "A1", reply: "1")

    result = RpmsRpc::Referral.record_status(IEN, "A1")

    assert result[:success], result.inspect
    assert_equal "A1", result[:status]
    assert_equal "A", result[:previous_status]
    assert_equal "1", result[:raw].to_s
    sent = status_calls(mock)
    assert_equal 1, sent.size
    assert_equal [ IEN, "A1" ], sent.first[:params].to_a, "REFIEN and STATUS, nothing else"
    assert_equal "BMCRPC", sent.first[:context]
    rpcs = mock.received_calls.map { |c| c[:rpc] }
    at = rpcs.index(STATUS_RPC)
    assert_includes rpcs[0...at], GETS_RPC, ".15 is read before the update"
    assert_includes rpcs[(at + 1)..], GETS_RPC, ".15 is read back after the update"
    ddr = mock.received_calls.select { |c| c[:rpc].start_with?("DDR") }
    assert(ddr.all? { |c| c[:context] == SIGN_ON_CONTEXT }, "the DDR reads stay in the caller's option")
    assert_equal SIGN_ON_CONTEXT, mock.current_context
  end

  # The session holds an earlier failed write that this call re-filed, here
  # or on another referral: not a success even when .15 reads as sent.
  def test_a_refusal_reply_is_a_poisoned_session_whatever_the_read_back_says
    [ "A1", "A" ].each do |after|
      seeded_mock(before: "A", after: after, reply: STALE)

      result = RpmsRpc::Referral.record_status(IEN, "A1")

      expected = { success: false, error: :session_poisoned, status: after, previous_status: "A" }
      assert_equal expected, result.except(:message, :raw), ".15 reads #{after} after the update"
      assert_match(/session.*close/im, result[:message], "say that the broker session must be closed")
      assert_equal STALE, result[:raw].to_s
    end
  end

  def test_a_success_reply_is_not_filed_when_the_read_back_differs
    seeded_mock(before: "A", after: "A", reply: "1")

    result = RpmsRpc::Referral.record_status(IEN, "A1")

    refute result[:success], result.inspect
    assert_equal :not_filed, result[:error]
    assert_equal "A", result[:status]
    assert_equal "A", result[:previous_status]
    assert_kind_of String, result[:message]
    assert_equal "1", result[:raw].to_s
  end

  # After the write a caller must be able to tell "may have filed" from "did
  # not": an unreadable read-back is :unverified, never :not_filed.
  def test_a_read_back_that_cannot_be_read_is_unverified
    UNREADABLE.each do |what, read_back|
      mock = seeded_mock(before: "A", after: read_back, reply: "1")

      result = RpmsRpc::Referral.record_status(IEN, "A1")

      expected = { success: false, error: :unverified, status: nil, previous_status: "A" }
      assert_equal expected, result.except(:message, :raw), "#{what}: #{result.inspect}"
      assert_match(/may have (been )?filed/i, result[:message], what)
      assert_match(/resen[dt]/i, result[:message], "#{what}: say not to resend blindly")
      assert_equal "1", result[:raw].to_s, what
      assert_equal 1, status_calls(mock).size, what
      assert_equal [ LOCK_RPC, [ UNLOCK ] ], last_call(mock), "#{what}: the lock is released"
    end
  end

  def test_a_refusal_reply_is_a_poisoned_session_when_the_read_back_cannot_be_read
    seeded_mock(before: "A", after: UNREADABLE["no .15 row"], reply: STALE)

    result = RpmsRpc::Referral.record_status(IEN, "A1")

    expected = { success: false, error: :session_poisoned, status: nil, previous_status: "A" }
    assert_equal expected, result.except(:message, :raw), result.inspect
  end

  # GETS with flags "I" answers a row for every requested field, empty ones
  # included: a reply without the .15 row was not read.
  def test_a_read_without_the_status_row_is_unread_and_nothing_is_sent
    UNREADABLE.slice("no .15 row", "another field's row only").each do |what, read|
      mock = seeded_mock(before: read, after: "A1", reply: "1")

      result = RpmsRpc::Referral.record_status(IEN, "A1")

      assert_equal({ success: false, error: :unread, raw: nil }, result.except(:message), "#{what}: #{result.inspect}")
      assert_empty status_calls(mock), what
      assert_equal [ LOCK_RPC, [ UNLOCK ] ], last_call(mock), "#{what}: the lock is released"
    end
  end

  # UPDTSTRF takes no lock; FileMan's editors and other gem callers lock the
  # entry, so an edit between the read and the update cannot be overwritten.
  def test_the_entry_is_locked_from_before_the_read_until_after_the_read_back
    mock = seeded_mock(before: "A", after: "A1", reply: "1")

    assert RpmsRpc::Referral.record_status(IEN, "A1")[:success]

    assert_equal [ LOCK_RPC, GETS_RPC, STATUS_RPC, GETS_RPC, LOCK_RPC ], mock.received_calls.map { |c| c[:rpc] }
    assert_equal [ LOCK ], mock.received_calls.first[:params].to_a, "incremental lock on the entry, timeout 5"
    assert_equal [ UNLOCK ], mock.received_calls.last[:params].to_a
    assert_equal [ SIGN_ON_CONTEXT ] * 2, mock.received_calls.values_at(0, -1).map { |c| c[:context] }
  end

  def test_an_entry_locked_by_someone_else_is_refused_and_nothing_else_is_sent
    { "timed out" => false, "no reply" => nil }.each do |what, lock|
      mock = seeded_mock(before: "A", after: "A1", reply: "1", lock: lock)

      result = RpmsRpc::Referral.record_status(IEN, "A1")

      assert_equal({ success: false, error: :locked, raw: nil }, result.except(:message), "#{what}: #{result.inspect}")
      assert_kind_of String, result[:message], what
      assert_equal [ [ LOCK_RPC, [ LOCK ] ] ], mock.received_calls.map { |c| [ c[:rpc], c[:params].to_a ] }, what
    end
  end

  def test_a_bad_ien_is_refused_without_the_wire
    RpmsRpc.mock!
    [ nil, "", "0", "abc", "1,2", "7abc", "+7" ].each do |ien|
      result = RpmsRpc::Referral.record_status(ien, "A")
      assert_equal({ success: false, error: :invalid_ien, raw: nil }, result.except(:message), ien.inspect)
      assert_kind_of String, result[:message]
    end
    assert_empty RpmsRpc.client.received_calls
  end

  def test_a_status_outside_the_set_of_codes_is_refused_without_the_wire
    RpmsRpc.mock!
    [ "H", "a", "", nil, "ACTIVE" ].each do |status|
      result = RpmsRpc::Referral.record_status(IEN, status)
      assert_equal({ success: false, error: :invalid_status, raw: nil }, result.except(:message), status.inspect)
      assert_kind_of String, result[:message]
    end
    assert_empty RpmsRpc.client.received_calls
  end

  def test_a_referral_not_on_file_is_refused_before_the_update
    mock = seeded_mock(before: UNREADABLE["an error"], after: "A1", reply: "1")

    result = RpmsRpc::Referral.record_status(IEN, "A1")

    refute result[:success]
    assert_equal :not_found, result[:error]
    assert_nil result[:raw]
    assert_empty status_calls(mock)
    assert_equal [ LOCK_RPC, [ UNLOCK ] ], last_call(mock), "the lock is released"
  end

  def test_a_broker_refusal_propagates
    mock = seeded_mock(before: "A", after: "A", reply: "1")
    refuse = ->(rpc) { raise RpmsRpc::Client::RpcRefusedError, "Access denied for remote procedure: #{rpc}" if rpc == STATUS_RPC }
    seeded = mock.method(:seeded_reply)
    mock.define_singleton_method(:seeded_reply) { |rpc, *params| seeded.call(rpc, *params).tap { refuse.call(rpc) } }

    error = assert_raises(RpmsRpc::Client::RpcRefusedError) { RpmsRpc::Referral.record_status(IEN, "A1") }
    assert_match(/Access denied/, error.message)
    assert_equal [ LOCK_RPC, [ UNLOCK ] ], last_call(mock), "the lock is released when the update raises"
  end

  private

  # .15 reads `before` until BMC REFERRAL STATUS UPDATE has been received,
  # then `after`: what the routine filed, whatever it answered. Each is a
  # status code or a whole DDR GETS ENTRY DATA reply ("" is no reply). The
  # lock on NODE (timeout 5) answers `lock` (nil: not seeded, no reply) and
  # the unlock "1"; any other node or timeout is not seeded.
  def seeded_mock(before:, after:, reply:, lock: true)
    mock = RpmsRpc.mock!
    mock.instance_variable_set(:@current_context, SIGN_ON_CONTEXT)
    mock.seed_scalar(:ddr_lock_unlock_node, LOCK.to_s, lock) unless lock.nil?
    mock.seed_scalar(:ddr_lock_unlock_node, UNLOCK.to_s, true)
    mock.seed_scalar(:bmc_referral_status_update, IEN, reply)
    reads = [ before, after ].map { |read| read.match?(/\A[A-Z]\w*\z/) ? "[Data]\n90001^#{IEN},^.15^#{read}" : read }
    read = reads.first
    mock.define_singleton_method(:seeded_reply) do |rpc, *params|
      seeded = super(rpc, *params)
      read = reads.last if rpc == STATUS_RPC
      rpc == GETS_RPC && params.first == GETS ? read.split("\n") : seeded
    end
    mock
  end

  def last_call(mock)
    mock.received_calls.last.then { |c| [ c[:rpc], c[:params].to_a ] }
  end

  def status_calls(mock)
    mock.received_calls.select { |c| c[:rpc] == STATUS_RPC }
  end
end
