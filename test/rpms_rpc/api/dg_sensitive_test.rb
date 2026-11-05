# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/reply"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/dg_sensitive"
require_relative "../stock_rpcs_test_helper"

# DG SENSITIVE RECORD ACCESS (PTSEC^DGSEC4) and DG SENSITIVE RECORD BULLETIN
# (NOTICE^DGSEC4) — BPRM 6.0 stored-procedure replacements for the legacy AG
# sensitive-access RPCs (rpms-rpc#420). Synthetic wire only.
class DgSensitiveTest < Minitest::Test
  include StockRpcsTestHelper

  Mod = RpmsRpc::DgSensitive
  RS = "\x1e"
  US = "\x1f"
  DFN = "990042"

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # PTSEC^DGSEC4 (DGSEC4.m:13-66): return-type 2 — one line per RESULT(n),
  # no typed header, no $C(30)/$C(31) sentinels. RESULT(1) is the code;
  # RESULT(2+) are messages.
  def test_parse_access_reply_maps_result_code_and_messages
    parsed = Mod.parse_access_reply([ "2", "Privacy act warning line" ])

    assert_equal 2, parsed[:result]
    assert_equal [ "Privacy act warning line" ], parsed[:messages]
    refute parsed.key?(:dfn), "PTSEC never returns a DFN slot"
  end

  def test_parse_access_reply_success_code_zero_has_no_messages
    parsed = Mod.parse_access_reply([ "0" ])

    assert_equal 0, parsed[:result]
    assert_equal [], parsed[:messages]
    refute parsed.key?(:dfn)
  end

  def test_parse_access_reply_restricted_access_is_code_five
    parsed = Mod.parse_access_reply([ "5", "Sorry, you are restricted from accessing this patient's record." ])

    assert_equal 5, parsed[:result]
    refute parsed.key?(:dfn)
  end

  def test_parse_access_reply_denied_own_record_is_code_three
    assert_equal 3, Mod.parse_access_reply([ "3" ])[:result]
  end

  def test_parse_access_reply_nil_on_empty_or_non_integer_first_line
    assert_nil Mod.parse_access_reply(nil)
    assert_nil Mod.parse_access_reply([])
    assert_nil Mod.parse_access_reply([ "" ])
    assert_nil Mod.parse_access_reply([ "X" ])
    assert_nil Mod.parse_access_reply([ "2^990042" ])
  end

  def test_parse_access_reply_accepts_reply_object
    reply = RpmsRpc::Reply.from_wire([ "2", "Privacy act warning line" ])
    parsed = Mod.parse_access_reply(reply)

    assert_equal 2, parsed[:result]
    refute parsed.key?(:dfn)
  end

  # NOTICE^DGSEC4 (DGSEC4.m:67-84): single-value RESULT 1/0.
  def test_parse_bulletin_result_success_and_failure
    assert Mod.parse_bulletin_result("1")[:success]
    refute Mod.parse_bulletin_result("0")[:success]
    assert_nil Mod.parse_bulletin_result("")
  end

  def test_check_access_uses_call_rpc_not_call_rpc_global_array
    calls = []
    client = Class.new do
      define_method(:call_rpc) do |rpc, *params|
        calls << { rpc: rpc, params: params }
        [ "0" ]
      end
      define_method(:call_rpc_global_array) do |*, **|
        raise "PTSEC must use call_rpc (array lines), not call_rpc_global_array"
      end
    end.new

    RpmsRpc.configure { |cfg| cfg.client = client }

    result = Mod.check_access(dfn: DFN.to_i, generate_message: 0, option: "SYNTH^MENU")

    assert_equal({ result: 0, messages: [] }, result)
    assert_equal 1, calls.size
    assert_equal "DG SENSITIVE RECORD ACCESS", calls[0][:rpc]
    assert_equal [ DFN, "0", "SYNTH^MENU" ], calls[0][:params]
  end

  def test_check_access_sends_dfn_dgmsg_and_dgopt
    seed_access([ "0" ])

    Mod.check_access(dfn: DFN.to_i, generate_message: 0, option: "SYNTH^MENU")

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "DG SENSITIVE RECORD ACCESS" }
    refute_nil call
    assert_equal [ DFN, "0", "SYNTH^MENU" ], call[:params]
    assert_equal Mod::CONTEXT, call[:context]
  end

  def test_check_access_parses_line_array_reply
    seed_access([ "2", "Privacy act warning line" ])

    result = Mod.check_access(dfn: DFN.to_i, generate_message: 0, option: "SYNTH^MENU")

    assert_equal 2, result[:result]
    assert_includes result[:messages].join(" "), "Privacy act"
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "DG SENSITIVE RECORD ACCESS" }
    assert_equal Mod::CONTEXT, call[:context]
  end

  def test_check_access_missing_dfn_surfaces_rpc_failure_code
    result = Mod.check_access(dfn: nil, generate_message: 1)

    assert_equal(-1, result[:result])
    assert_match(/Required variable missing/, result[:messages].join)
  end

  def test_record_bulletin_sends_dfn_action_and_dgopt
    RpmsRpc.client.seed_scalar(:dg_sensitive_bulletin, DFN, "1")

    Mod.record_bulletin(dfn: DFN.to_i, action: 3, option: "SYNTH^MENU")

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "DG SENSITIVE RECORD BULLETIN" }
    assert_equal [ DFN, "SYNTH^MENU", "3" ], call[:params]
    assert_equal Mod::CONTEXT, call[:context]
  end

  def test_record_bulletin_is_non_idempotent_write_in_retry_safety
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(Mod, :record_bulletin)
  end

  def test_check_access_is_non_idempotent_write_in_retry_safety
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(Mod, :check_access)
  end

  def test_context_matches_pinned_registry
    rpc = pinned_rpc("DG SENSITIVE RECORD ACCESS")
    assert_includes rpc.contexts, Mod::CONTEXT
    assert_equal "PTSEC^DGSEC4", rpc.entry_point
  end

  def test_required_rpcs_lists_both_dg_sensitive_rpcs_under_dg_sensitive
    assert_required_rpc "DG SENSITIVE RECORD ACCESS", "DG SENSITIVE RECORD BULLETIN", under: "RpmsRpc::DgSensitive"
  end

  # CiaClient#authenticate leaves CIAV VUECENTRIC bound; ContextScope restores it.
  def test_check_access_scopes_or_cprs_gui_chart_on_ciav_session
    mock = RpmsRpc.client
    mock.create_context("CIAV VUECENTRIC")
    seed_access([ "0" ])

    Mod.check_access(dfn: DFN.to_i)

    call = mock.received_calls.find { |c| c[:rpc] == "DG SENSITIVE RECORD ACCESS" }
    refute_nil call
    assert_equal Mod::CONTEXT, call[:context]
    assert_equal "CIAV VUECENTRIC", mock.current_context
  end

  def test_record_bulletin_scopes_or_cprs_gui_chart_on_ciav_session
    mock = RpmsRpc.client
    mock.create_context("CIAV VUECENTRIC")
    mock.seed_scalar(:dg_sensitive_bulletin, DFN, "1")

    Mod.record_bulletin(dfn: DFN.to_i, action: 3, option: "SYNTH^MENU")

    call = mock.received_calls.find { |c| c[:rpc] == "DG SENSITIVE RECORD BULLETIN" }
    refute_nil call
    assert_equal Mod::CONTEXT, call[:context]
    assert_equal "CIAV VUECENTRIC", mock.current_context
  end

  private

  def seed_access(lines)
    tables = RpmsRpc.client.instance_variable_get(:@lines) || {}
    tables["DG SENSITIVE RECORD ACCESS"] ||= {}
    tables["DG SENSITIVE RECORD ACCESS"][DFN] = Array(lines)
    RpmsRpc.client.instance_variable_set(:@lines, tables)
  end
end
