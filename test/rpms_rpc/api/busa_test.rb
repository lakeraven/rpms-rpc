# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/busa"
require_relative "../captured_replies"
require_relative "../stock_rpcs_test_helper"

# BUSA LOG SECURITY AUDIT ENTRY (RPC^BUSARPC, BUSARPC.m:304-386) — rpms-rpc#420.
# Each test replays a call the gem made as PROVIDER,TEST on a throwaway
# container where PROVIDER,TEST was given BUSARPC, which no published demo
# persona holds (test/fixtures/captured_replies/busa-log.yml).
class BusaTest < Minitest::Test
  include StockRpcsTestHelper

  Mod = RpmsRpc::Busa
  SLUG = "busa-log"
  SYSTEM_EVENT = { category: "S", action: "", call: "SYNTH RPC", description: "Synthetic system event", detail: "" }.freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow = nil)
    @client = CapturedReplies::ReplayCiaClient.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {})
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
  def contexts = @client.calls.select { |c| c[:rpc] == :create_context }.map { |c| c[:params].first }

  # RPC^BUSARPC answers header I00001RESULT^T00250ERROR_MESSAGE then RESULT, 1
  # when $$LOG^BUSAAPI filed the entry. INPUT is one parameter, pipe-delimited
  # CAT|ACTION|CALL|DESC|DETAIL (BUSARPC.m:363-367), sent under BUSARPC.
  def test_log_security_audit_logs_and_sends_one_pipe_delimited_parameter
    replay("logged")

    assert_equal({ success: true, message: "" }, Mod.log_security_audit(**SYSTEM_EVENT))
    assert_equal [ [ "BUSA LOG SECURITY AUDIT ENTRY", [ "S||SYNTH RPC|Synthetic system event|" ] ] ], sent
    assert_equal CapturedReplies.flow_calls(SLUG, "logged"), sent
    assert_equal [ Mod::CONTEXT, CapturedReplies::ReplayCiaClient::SIGNON_CONTEXT ], contexts
  end

  # $$LOG^BUSAAPI refuses an event with no description and says why.
  def test_log_security_audit_reads_the_builds_refusal_message
    replay("no_description")

    assert_equal({ success: false, message: "Invalid DESC value" },
                 Mod.log_security_audit(**SYSTEM_EVENT, description: ""))
  end

  # On the build, an event whose DETAIL names a patient answers 0^ with no
  # message: the detail row is refused after the summary entry is filed. The
  # gem reads it as a failure, never as logged.
  def test_log_security_audit_reads_a_bare_refusal_as_not_logged
    replay("patient_detail")

    result = Mod.log_security_audit(category: "P", action: "E", call: "SYNTH RPC",
                                    description: "Synthetic demographic update", detail: "990031")

    assert_equal({ success: false, message: "" }, result)
    assert_equal CapturedReplies.flow_calls(SLUG, "patient_detail"), sent
  end

  def test_parse_log_reply_accepts_the_line_array_call_rpc_gives
    lines = CapturedReplies.raw(SLUG, "no_description/1").byteslice(2..).force_encoding(Encoding::UTF_8).split("\x1e")

    assert_equal({ success: false, message: "Invalid DESC value" }, Mod.parse_log_reply(lines))
  end

  def test_log_security_audit_is_non_idempotent_write_in_retry_safety
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(Mod, :log_security_audit)
  end

  # BUSARPC.m:363-367 splits INPUT on "|"; a piece containing "|" must be refused client-side.
  def test_log_security_audit_rejects_pipe_in_any_piece
    replay
    SYSTEM_EVENT.each_key do |field|
      assert_raises(ArgumentError) { Mod.log_security_audit(**SYSTEM_EVENT, field => "a|b") }
    end
    assert_empty sent
  end

  def test_context_is_busa_rpc_on_the_pinned_build
    assert_includes pinned_rpc("BUSA LOG SECURITY AUDIT ENTRY").contexts, Mod::CONTEXT
  end

  def test_required_rpcs_lists_busa_log_under_busa
    assert_required_rpc "BUSA LOG SECURITY AUDIT ENTRY", under: "RpmsRpc::Busa"
  end
end
