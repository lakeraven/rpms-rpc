# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/bgu"
require_relative "../stock_rpcs_test_helper"

# BGU MAILMAN MESSAGE (EN^BGUMAIL, BGUMAIL.m:3-7) — rpms-rpc#420.
class BguMailTest < Minitest::Test
  include StockRpcsTestHelper

  Mod = RpmsRpc::Bgu
  GROUP = "SYNTH.GROUP"
  SUBJECT = "Synthetic subject"
  BODY = "Synthetic line one"

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # EN^BGUMAIL sets BGUARRAY(1)=1 and BGUARRAY(2)="OK" on success (BGUMAIL.m:6-7).
  def test_send_mailman_message_parses_ok_array
    RpmsRpc.client.seed_collection(:bgu_mailman_message, [ { result: "1", status: "OK" } ])

    result = Mod.send_mailman_message(subject: SUBJECT, body: BODY, group: GROUP)

    assert result[:success]
    assert_equal "OK", result[:status]
  end

  # BGUDATA lines split on $C(175) (BGUMAIL.m:11); subject and group are separate formals.
  def test_send_mailman_message_sends_subject_body_and_group
    RpmsRpc.client.seed_collection(:bgu_mailman_message, [ { result: "1", status: "OK" } ])

    Mod.send_mailman_message(subject: SUBJECT, body: BODY, group: GROUP)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGU MAILMAN MESSAGE" }
    assert_equal [ SUBJECT, BODY, GROUP ], call[:params]
    assert_equal Mod::CONTEXT, call[:context]
  end

  def test_send_mailman_message_is_non_idempotent_write_in_retry_safety
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(Mod, :send_mailman_message)
  end

  def test_context_is_ciav_vuecentric_on_the_pinned_build
    assert_includes pinned_rpc("BGU MAILMAN MESSAGE").contexts, Mod::CONTEXT
  end

  def test_required_rpcs_lists_bgu_mailman_under_bgu
    assert_required_rpc "BGU MAILMAN MESSAGE", under: "RpmsRpc::Bgu"
  end
end
