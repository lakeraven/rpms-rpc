# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/referral"
require_relative "../captured_replies"

# Referral.find (BMC GET REFERRAL, GTRFBYID^BMCRPC1) on the replies a fresh
# rpms-ydb container sent (test/fixtures/captured_replies/bmc-get-referral.yml),
# replayed through CiaClient: the refusal cases, per ADR 0009. The record read
# is not pinned here: on the pinned build the only referral a fresh container
# can get (the minimal one test/live/referral_cancel_live_test.rb files) has no
# referral number, and GTRFBYID answers an M error for it.
#
# This file used to seed three referral hashes into MockClient and read them
# back, which asserted the fake and nothing RPMS sent (rpms-rpc#622).
class ReferralLifecycleTest < Minitest::Test
  SLUG = "bmc-get-referral"
  RPC = "BMC GET REFERRAL"

  def teardown
    RpmsRpc.reset!
  end

  def replay(name)
    client = CapturedReplies::ReplayCiaClient.new(RPC => [ CapturedReplies.raw(SLUG, name) ])
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent(name) = CapturedReplies.file(SLUG).fetch("captures").find { |c| c["name"] == name }.fetch("inputs")

  # An M error inside GTRFBYID is never a referral, nor "no referral".
  def test_an_m_error_inside_the_read_raises
    client = replay("m_error")

    error = assert_raises(RpmsRpc::Client::RpcMError) { RpmsRpc::Referral.find("1") }
    assert_includes error.message, "GTRFBYID+31^BMCRPC1"
    assert_equal [ sent("m_error") ], client.calls.select { |c| c[:rpc] == RPC }.map { |c| c[:params] }
  end

  # For an IEN no referral has, GTRFBYID sets its message as the result
  # (BMCRPC1.m:57), and on the pinned build the broker answers an M error in
  # OUT^CIANBACT for that reply. It raises, rather than reading as a record.
  def test_an_ien_with_no_referral_raises_rather_than_reading_as_a_record
    replay("no_such_referral")

    error = assert_raises(RpmsRpc::Client::RpcMError) { RpmsRpc::Referral.find("999999999") }
    assert_includes error.message, "OUT+5^CIANBACT"
  end

  def test_a_nil_ien_reaches_no_wire
    client = replay("m_error")

    assert_nil RpmsRpc::Referral.find(nil)
    assert_empty client.calls
  end
end
