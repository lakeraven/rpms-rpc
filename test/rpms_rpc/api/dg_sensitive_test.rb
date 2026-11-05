# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
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

  # PTSEC^DGSEC4 (DGSEC4.m:13-66): RESULT(1) codes -1..5; messages in RESULT(2+).
  ACCESS_HEADER = "I00010RESULT^I00010DFN^T00100DGMSG^T00030DGOPT"

  def test_parse_access_reply_maps_result_code_and_messages
    raw = "#{ACCESS_HEADER}#{RS}2^#{DFN}^^SYNTH OPTION^MENU#{RS}Privacy act warning line#{RS}#{US}"

    parsed = Mod.parse_access_reply(raw)

    assert_equal 2, parsed[:result]
    assert_equal DFN, parsed[:dfn]
    assert_includes parsed[:messages].join(" "), "Privacy act"
  end

  def test_parse_access_reply_denied_own_record_is_code_three
    raw = "#{ACCESS_HEADER}#{RS}3^#{DFN}^^^#{RS}Access denied#{RS}#{US}"

    assert_equal 3, Mod.parse_access_reply(raw)[:result]
  end

  def test_parse_access_reply_nil_on_empty
    assert_nil Mod.parse_access_reply(nil)
    assert_nil Mod.parse_access_reply("")
  end

  # NOTICE^DGSEC4 (DGSEC4.m:67-84): single-value RESULT 1/0.
  def test_parse_bulletin_result_success_and_failure
    assert Mod.parse_bulletin_result("1")[:success]
    refute Mod.parse_bulletin_result("0")[:success]
    assert_nil Mod.parse_bulletin_result("")
  end

  def test_check_access_sends_dfn_dgmsg_and_dgopt
    seed_access("0^#{DFN}^^^#{RS}#{US}")

    Mod.check_access(dfn: DFN.to_i, generate_message: 0, option: "SYNTH^MENU")

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "DG SENSITIVE RECORD ACCESS" }
    refute_nil call
    assert_equal [ DFN, "0", "SYNTH^MENU" ], call[:params]
    assert_equal Mod::CONTEXT, call[:context]
  end

  def test_check_access_missing_dfn_surfaces_rpc_failure_code
    seed_access("-1^#{RS}Required variable missing.#{RS}#{US}")

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

  def test_check_access_is_read_in_retry_safety
    assert_equal :read, RpmsRpc::RetrySafety.for(Mod, :check_access)
  end

  def test_context_matches_pinned_registry
    rpc = pinned_rpc("DG SENSITIVE RECORD ACCESS")
    assert_includes rpc.contexts, Mod::CONTEXT
    assert_equal "PTSEC^DGSEC4", rpc.entry_point
  end

  def test_required_rpcs_lists_both_dg_sensitive_rpcs_under_dg_sensitive
    assert_required_rpc "DG SENSITIVE RECORD ACCESS", "DG SENSITIVE RECORD BULLETIN", under: "RpmsRpc::DgSensitive"
  end

  # DG sensitive RPCs are not registered under CIAV VUECENTRIC (contexts_19_05).
  def test_check_access_raises_when_bound_option_does_not_serve_the_rpc
    mock = RpmsRpc.mock!
    mock.create_context("CIAV VUECENTRIC")

    assert_raises(RpmsRpc::Client::RpcNotAvailableError) { Mod.check_access(dfn: 1) }
    assert_empty mock.received_calls
  end

  private

  def seed_access(body)
    wire = "5\x00#{ACCESS_HEADER}#{RS}#{body}"
    tables = RpmsRpc.client.instance_variable_get(:@lines) || {}
    tables["DG SENSITIVE RECORD ACCESS"] = { DFN => wire }
    RpmsRpc.client.instance_variable_set(:@lines, tables)
  end
end
