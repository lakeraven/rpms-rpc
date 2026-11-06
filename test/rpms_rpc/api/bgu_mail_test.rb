# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/bgu"
require_relative "../stock_rpcs_test_helper"

# BGU MAILMAN MESSAGE (EN^BGUMAIL, BGUMAIL.m:3-7) — rpms-rpc#420.
# EN(BGUARRAY,BGUDATA,BGUSBJ,BGUGROUP): wire params are body, subject, group.
class BguMailTest < Minitest::Test
  include StockRpcsTestHelper

  Mod = RpmsRpc::Bgu
  GROUP = "SYNTH GROUP"
  SUBJECT = "Synthetic subject"
  BODY = "Synthetic line one"
  # $C(175) in M is byte 0xAF (ISO-8859-1); body lines are joined on the wire with this octet.
  C175 = "\xaf"

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def mail_calls
    RpmsRpc.client.received_calls.select { |c| c[:rpc] == "BGU MAILMAN MESSAGE" }
  end

  # EN^BGUMAIL sets BGUARRAY(1)=1 and BGUARRAY(2)="OK" on success (BGUMAIL.m:6-7).
  def test_send_mailman_message_parses_ok_array
    RpmsRpc.client.seed_collection(:bgu_mailman_message, [ { result: "1", status: "OK" } ])

    result = Mod.send_mailman_message(subject: SUBJECT, body: BODY, group: GROUP)

    assert result[:success]
    assert_equal "OK", result[:status]
  end

  def test_send_mailman_message_not_success_when_result_is_not_one
    RpmsRpc.client.seed_collection(:bgu_mailman_message, [ { result: "0", status: "OK" } ])

    result = Mod.send_mailman_message(subject: SUBJECT, body: BODY, group: GROUP)

    refute result[:success]
  end

  def test_send_mailman_message_not_success_when_status_is_not_ok
    RpmsRpc.client.seed_collection(:bgu_mailman_message, [ { result: "1", status: "FAIL" } ])

    result = Mod.send_mailman_message(subject: SUBJECT, body: BODY, group: GROUP)

    refute result[:success]
  end

  # BGUDATA is wire param 0; BGUSBJ and BGUGROUP follow (BGUMAIL.m:3-7).
  def test_send_mailman_message_sends_body_subject_and_group
    RpmsRpc.client.seed_collection(:bgu_mailman_message, [ { result: "1", status: "OK" } ])

    Mod.send_mailman_message(subject: SUBJECT, body: BODY, group: GROUP)

    call = mail_calls.sole
    assert_equal [ BODY, SUBJECT, GROUP ], call[:params]
    assert_equal Mod::CONTEXT, call[:context]
  end

  # MAIL^BGUMAIL splits BGUDATA on $C(175) (BGUMAIL.m:11).
  def test_send_mailman_message_joins_multiline_body_with_c175_on_the_wire
    RpmsRpc.client.seed_collection(:bgu_mailman_message, [ { result: "1", status: "OK" } ])
    line_one = "Synthetic line one"
    line_two = "Synthetic line two"

    Mod.send_mailman_message(subject: SUBJECT, body: "#{line_one}\n#{line_two}", group: GROUP)

    wire_body = mail_calls.sole[:params][0]
    assert_equal "#{line_one}#{C175}#{line_two}", wire_body
  end

  def test_send_mailman_message_refuses_body_with_c175_before_rpc
    assert_raises(ArgumentError) do
      Mod.send_mailman_message(subject: SUBJECT, body: "line#{C175}two", group: GROUP)
    end
    assert_empty mail_calls
  end

  def test_send_mailman_message_refuses_subject_with_pipe_before_rpc
    assert_raises(ArgumentError) do
      Mod.send_mailman_message(subject: "sub|ject", body: BODY, group: GROUP)
    end
    assert_empty mail_calls
  end

  def test_send_mailman_message_refuses_group_with_caret_before_rpc
    assert_raises(ArgumentError) do
      Mod.send_mailman_message(subject: SUBJECT, body: BODY, group: "G^ROUP")
    end
    assert_empty mail_calls
  end

  def test_send_mailman_message_refuses_group_with_invalid_characters_before_rpc
    assert_raises(ArgumentError) do
      Mod.send_mailman_message(subject: SUBJECT, body: BODY, group: "SYNTH.GROUP")
    end
    assert_empty mail_calls
  end

  def test_send_mailman_message_refuses_control_bytes_before_rpc
    assert_raises(ArgumentError) do
      Mod.send_mailman_message(subject: SUBJECT, body: "line\x01two", group: GROUP)
    end
    assert_empty mail_calls
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
