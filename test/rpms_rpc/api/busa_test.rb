# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/busa"
require_relative "../stock_rpcs_test_helper"

# BUSA LOG SECURITY AUDIT ENTRY (RPC^BUSARPC, BUSARPC.m:304-386) — rpms-rpc#420.
class BusaTest < Minitest::Test
  include StockRpcsTestHelper

  Mod = RpmsRpc::Busa
  RS = "\x1e"
  US = "\x1f"

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # RPC^BUSARPC builds header I00001RESULT^T00250ERROR_MESSAGE (BUSARPC.m:354).
  def test_parse_log_reply_success_and_failure
    raw = "5\x00I00001RESULT^T00250ERROR_MESSAGE#{RS}1^#{RS}#{US}"
    assert Mod.parse_log_reply(raw)[:success]

    raw_fail = "5\x00I00001RESULT^T00250ERROR_MESSAGE#{RS}0^DUZ is not defined#{RS}#{US}"
    parsed = Mod.parse_log_reply(raw_fail)
    refute parsed[:success]
    assert_match(/DUZ is not defined/, parsed[:message])
  end

  # INPUT is pipe-delimited CAT|ACTION|CALL|DESC|DETAIL (BUSARPC.m:363-367).
  def test_log_security_audit_encodes_input_pipe_and_sends_one_parameter
    wire = "5\x00I00001RESULT^T00250ERROR_MESSAGE#{RS}1^#{RS}#{US}"
    seed_log("", wire)

    Mod.log_security_audit(
      category: "P",
      action: "E",
      call: "SYNTH RPC",
      description: "Synthetic demographic update",
      detail: "990031"
    )

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BUSA LOG SECURITY AUDIT ENTRY" }
    assert_equal [ "P|E|SYNTH RPC|Synthetic demographic update|990031" ], call[:params]
    assert_equal Mod::CONTEXT, call[:context]
  end

  def test_log_security_audit_is_non_idempotent_write_in_retry_safety
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(Mod, :log_security_audit)
  end

  # BUSARPC.m:363-367 splits INPUT on "|"; a piece containing "|" must be refused client-side.
  def test_log_security_audit_rejects_pipe_in_any_piece
    base = {
      category: "P",
      action: "E",
      call: "SYNTH RPC",
      description: "Synthetic demographic update",
      detail: "990031"
    }
    base.each_key do |field|
      RpmsRpc.client.received_calls.clear
      assert_raises(ArgumentError) { Mod.log_security_audit(**base.merge(field => "a|b")) }
      assert_empty busa_calls, "field #{field} with embedded pipe must not call BUSA"
    end
  end

  def test_context_is_busa_rpc_on_the_pinned_build
    assert_includes pinned_rpc("BUSA LOG SECURITY AUDIT ENTRY").contexts, Mod::CONTEXT
  end

  def test_required_rpcs_lists_busa_log_under_busa
    assert_required_rpc "BUSA LOG SECURITY AUDIT ENTRY", under: "RpmsRpc::Busa"
  end

  private

  def busa_calls
    RpmsRpc.client.received_calls.select { |c| c[:rpc] == "BUSA LOG SECURITY AUDIT ENTRY" }
  end

  def seed_log(_key, wire)
    tables = RpmsRpc.client.instance_variable_get(:@lines) || {}
    tables["BUSA LOG SECURITY AUDIT ENTRY"] = { "" => wire }
    RpmsRpc.client.instance_variable_set(:@lines, tables)
  end
end
