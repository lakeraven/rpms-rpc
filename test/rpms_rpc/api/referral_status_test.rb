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
# whatever .15 reads. Every reply here is seeded, so these tests prove the
# frame and the guards, not the build:
# test/live/referral_status_live_test.rb is the live proof.
class ReferralStatusTest < Minitest::Test
  IEN = "7"
  SIGN_ON_CONTEXT = "CIAV VUECENTRIC"
  STATUS_RPC = "BMC REFERRAL STATUS UPDATE"
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
    assert_includes rpcs[0...at], "DDR GETS ENTRY DATA", ".15 is read before the update"
    assert_includes rpcs[(at + 1)..], "DDR GETS ENTRY DATA", ".15 is read back after the update"
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
    mock = RpmsRpc.mock!
    mock.seed(:ddr_gets_entry_data, status_key, "[ERROR]\n[BEGIN_diERRORS]\n601^The entry does not exist.\n[END_diERRORS]")

    result = RpmsRpc::Referral.record_status(IEN, "A1")

    refute result[:success]
    assert_equal :not_found, result[:error]
    assert_nil result[:raw]
    assert_empty status_calls(mock)
  end

  def test_a_broker_refusal_propagates
    mock = seeded_mock(before: "A", after: "A", reply: "1")
    refuse = ->(rpc) { raise RpmsRpc::Client::RpcRefusedError, "Access denied for remote procedure: #{rpc}" if rpc == STATUS_RPC }
    mock.define_singleton_method(:seeded_reply) { |rpc, *params| super(rpc, *params).tap { refuse.call(rpc) } }

    error = assert_raises(RpmsRpc::Client::RpcRefusedError) { RpmsRpc::Referral.record_status(IEN, "A1") }
    assert_match(/Access denied/, error.message)
  end

  private

  # .15 reads `before` until BMC REFERRAL STATUS UPDATE has been received,
  # then `after`: what the routine filed, whatever it answered.
  def seeded_mock(before:, after:, reply:)
    mock = RpmsRpc.mock!
    mock.instance_variable_set(:@current_context, SIGN_ON_CONTEXT)
    key = status_key
    mock.seed(:ddr_gets_entry_data, key, "[Data]\n90001^#{IEN},^.15^#{before}")
    mock.seed_scalar(:bmc_referral_status_update, IEN, reply)
    mock.define_singleton_method(:seeded_reply) do |rpc, *params|
      super(rpc, *params).tap do
        seed(:ddr_gets_entry_data, key, "[Data]\n90001^#{IEN},^.15^#{after}") if rpc == STATUS_RPC
      end
    end
    mock
  end

  def status_calls(mock)
    mock.received_calls.select { |c| c[:rpc] == STATUS_RPC }
  end

  def status_key
    RpmsRpc::DdrFileman.gets_entry_param(file: "90001", iens: "#{IEN},", fields: ".15", flags: "I").to_s
  end
end
