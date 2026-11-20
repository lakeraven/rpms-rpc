# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/referral"
require_relative "../captured_replies"

# Referral.find (BMC GET REFERRAL, GTRFBYID^BMCRPC1) on the replies a fresh
# rpms-ydb container sent (test/fixtures/captured_replies/bmc-get-referral.yml),
# replayed through CiaClient, per ADR 0009. find checks the entry with DDR
# GETS ENTRY DATA first, because the routine raises an M error both for an IEN
# not on file and for a referral with no REFERRAL # (.02) (#767); the find_*
# flows are what find sent for each case, and m_error / no_such_referral are
# what the routine answers when it is called for them anyway.
#
# It replaced hand-seeded referral rows, which proved nothing RPMS sent
# (rpms-rpc#622).
class ReferralLifecycleTest < Minitest::Test
  SLUG = "bmc-get-referral"
  RPC = "BMC GET REFERRAL"

  def teardown
    RpmsRpc.reset!
  end

  def replay_flow(name)
    client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(SLUG, name))
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent_rpcs(client) = client.calls.map { |c| c[:rpc] }

  # Called for a referral with no number, GTRFBYID dies at +31; called for an
  # IEN not on file, the broker answers an M error in OUT^CIANBACT. These are
  # the replies find no longer asks for.
  def test_the_routine_raises_for_both_cases_find_now_checks_first
    { "m_error" => "GTRFBYID+31^BMCRPC1", "no_such_referral" => "OUT+5^CIANBACT" }.each do |name, where|
      client = CapturedReplies::ReplayCiaClient.new(RPC => [ CapturedReplies.raw(SLUG, name) ])
      error = assert_raises(RpmsRpc::Client::RpcMError) { client.call_rpc(RPC, "1") }
      assert_includes error.message, where
    end
  end

  def test_a_referral_not_on_file_is_nil_and_bmc_get_referral_is_not_sent
    client = replay_flow("find_not_on_file")

    assert_nil RpmsRpc::Referral.find("999999999")
    assert_equal CapturedReplies.flow_calls(SLUG, "find_not_on_file").map(&:first), sent_rpcs(client) - [ :create_context ]
    refute_includes sent_rpcs(client), RPC
  end

  def test_a_referral_with_no_number_is_nil_and_bmc_get_referral_is_not_sent
    client = replay_flow("find_no_number")

    assert_nil RpmsRpc::Referral.find("1")
    refute_includes sent_rpcs(client), RPC
  end

  def test_a_numbered_referral_reads_as_its_record
    client = replay_flow("find_numbered")

    record = RpmsRpc::Referral.find("2")

    assert_equal CapturedReplies.flow_calls(SLUG, "find_numbered"), client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
    assert_equal "2", record[:ien]
    assert_equal "9000000000002", record[:referral_number]
    assert_equal 990_001, record[:patient_dfn]
    assert_equal [ "N", "O" ], record.values_at(:type, :visit_type)
    assert_equal "ACTIVE", record[:status]
    assert_empty record[:diagnoses]
  end

  def test_a_nil_ien_reaches_no_wire
    client = replay_flow("find_numbered")

    assert_nil RpmsRpc::Referral.find(nil)
    assert_empty client.calls
  end
end
