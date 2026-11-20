# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/bgu"
require_relative "../captured_replies"
require_relative "../stock_rpcs_test_helper"

# BGU MAILMAN MESSAGE (EN^BGUMAIL, BGUMAIL.m:3-7) — rpms-rpc#420.
# EN(BGUARRAY,BGUDATA,BGUSBJ,BGUGROUP): wire params are body, subject, group.
# Each test replays a send the gem made as PROVIDER,TEST on a throwaway
# container (test/fixtures/captured_replies/bgu-mailman-message.yml).
class BguMailTest < Minitest::Test
  include StockRpcsTestHelper

  Mod = RpmsRpc::Bgu
  SLUG = "bgu-mailman-message"
  GROUP = "BILLING"
  SUBJECT = "Synthetic subject"
  BODY = "Synthetic line one"
  # $C(175) in M is byte 0xAF (ISO-8859-1); body lines are joined on the wire with this octet.
  C175 = "\xaf"

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow = nil)
    script = flow ? CapturedReplies.flow_script(SLUG, flow) : {}
    @client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  # The [rpc, params] the gem sent, bytes compared (a joined body is not UTF-8).
  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params].map(&:b) ] }
  def recorded(flow) = CapturedReplies.flow_calls(SLUG, flow).map { |rpc, params| [ rpc, params.map(&:b) ] }
  def contexts = @client.calls.select { |c| c[:rpc] == :create_context }.map { |c| c[:params].first }

  # EN^BGUMAIL sets BGUARRAY(1)=1 and BGUARRAY(2)="OK" (BGUMAIL.m:6-7). MAIL^BGUMAIL
  # splits BGUDATA on $C(175) (BGUMAIL.m:11), so the gem joins body lines with it.
  def test_send_mailman_message_sends_a_multiline_body_and_reads_ok
    replay("sent")
    @client.create_context("OR CPRS GUI CHART") # a session bound elsewhere

    result = Mod.send_mailman_message(subject: SUBJECT, body: "#{BODY}\nSynthetic line two", group: GROUP)

    assert_equal({ success: true, status: "OK" }, result)
    assert_equal [ [ "BGU MAILMAN MESSAGE", [ "#{BODY}#{C175}Synthetic line two".b, SUBJECT, GROUP ] ] ], sent
    assert_equal recorded("sent"), sent
    assert_equal [ "OR CPRS GUI CHART", Mod::CONTEXT, "OR CPRS GUI CHART" ], contexts
  end

  # EN^BGUMAIL answers 1/OK on every path, even for a mail group the build does
  # not have: the reply cannot tell a delivered message from a lost one.
  def test_send_mailman_message_to_a_group_not_on_file_still_reads_ok
    replay("group_not_on_file")

    assert_equal({ success: true, status: "OK" },
                 Mod.send_mailman_message(subject: SUBJECT, body: BODY, group: "NOSUCH GROUP"))
    assert_equal recorded("group_not_on_file"), sent
  end

  def test_send_mailman_message_refuses_body_with_c175_before_rpc
    replay
    assert_raises(ArgumentError) do
      Mod.send_mailman_message(subject: SUBJECT, body: "line#{C175}two", group: GROUP)
    end
    assert_empty sent
  end

  def test_send_mailman_message_refuses_subject_with_pipe_before_rpc
    replay
    assert_raises(ArgumentError) do
      Mod.send_mailman_message(subject: "sub|ject", body: BODY, group: GROUP)
    end
    assert_empty sent
  end

  def test_send_mailman_message_refuses_group_with_caret_before_rpc
    replay
    assert_raises(ArgumentError) do
      Mod.send_mailman_message(subject: SUBJECT, body: BODY, group: "G^ROUP")
    end
    assert_empty sent
  end

  def test_send_mailman_message_refuses_group_with_invalid_characters_before_rpc
    replay
    assert_raises(ArgumentError) do
      Mod.send_mailman_message(subject: SUBJECT, body: BODY, group: "SYNTH.GROUP")
    end
    assert_empty sent
  end

  def test_send_mailman_message_refuses_control_bytes_before_rpc
    replay
    assert_raises(ArgumentError) do
      Mod.send_mailman_message(subject: SUBJECT, body: "line\x01two", group: GROUP)
    end
    assert_empty sent
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
