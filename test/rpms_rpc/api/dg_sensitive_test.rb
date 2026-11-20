# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/reply"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/dg_sensitive"
require_relative "../captured_replies"
require_relative "../stock_rpcs_test_helper"

# DG SENSITIVE RECORD ACCESS (PTSEC^DGSEC4) and DG SENSITIVE RECORD BULLETIN
# (NOTICE^DGSEC4) — BPRM 6.0 stored-procedure replacements for the legacy AG
# sensitive-access RPCs (rpms-rpc#420). Each test replays a call the gem made
# as PROVIDER,TEST on a throwaway container where DFN 990028 was made a
# sensitive record (test/fixtures/captured_replies/dg-sensitive.yml).
class DgSensitiveTest < Minitest::Test
  include StockRpcsTestHelper

  Mod = RpmsRpc::DgSensitive
  SLUG = "dg-sensitive"
  OPTION = "OR CPRS GUI CHART"

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow = nil)
    @client = CapturedReplies::ReplayCiaClient.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {})
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
  def contexts = @client.calls.select { |c| c[:rpc] == :create_context }.map { |c| c[:params].first }

  # PTSEC^DGSEC4 (DGSEC4.m:13-66): one line per RESULT(n), no typed header.
  # RESULT(1) is the code, 0 for a record that is not sensitive.
  def test_check_access_reads_code_zero_for_a_record_that_is_not_sensitive
    replay("not_sensitive")

    assert_equal({ result: 0, messages: [] }, Mod.check_access(dfn: 990_031, generate_message: 0, option: ""))
    assert_equal [ [ "DG SENSITIVE RECORD ACCESS", [ "990031", "0", "" ] ] ], sent
  end

  # A sensitive record reads code 2 with the routine's warning lines as messages.
  # CiaClient#authenticate leaves CIAV VUECENTRIC bound; the call runs under OR
  # CPRS GUI CHART, and ContextScope restores CIAV VUECENTRIC after.
  def test_check_access_reads_a_sensitive_record_warning_under_or_cprs_gui_chart
    replay("sensitive")

    result = Mod.check_access(dfn: 990_028, generate_message: 1, option: OPTION)

    assert_equal 2, result[:result]
    assert_equal [ "***WARNING***", "***RESTRICTED RECORD***" ], result[:messages].first(2)
    assert_includes result[:messages].join(" "), "Privacy Act of 1974"
    refute result.key?(:dfn), "PTSEC never returns a DFN slot"
    assert_equal CapturedReplies.flow_calls(SLUG, "sensitive"), sent
    assert_equal [ Mod::CONTEXT, "CIAV VUECENTRIC" ], contexts
  end

  # PTSEC^DGSEC4 answers 0 for a DFN no patient has: "not sensitive" is not
  # "on file".
  def test_check_access_reads_code_zero_for_a_dfn_not_on_file
    replay("not_on_file")

    assert_equal({ result: 0, messages: [] }, Mod.check_access(dfn: 999_999_999, generate_message: 0, option: ""))
  end

  # The gem answers a missing DFN as the routine itself does, without sending.
  def test_check_access_missing_dfn_answers_the_routines_own_reply_without_rpc
    replay

    built = Mod.parse_access_reply(CapturedReplies.raw(SLUG, "access_no_dfn").byteslice(2..))
    assert_equal({ result: -1, messages: [ "Required variable missing." ] }, built)
    assert_equal built, Mod.check_access(dfn: nil, generate_message: 1)
    assert_equal built, Mod.check_access(dfn: "  ", generate_message: 1)
    assert_empty sent
  end

  def test_parse_access_reply_accepts_reply_object
    lines = CapturedReplies.raw(SLUG, "sensitive/1").byteslice(2..).force_encoding(Encoding::UTF_8).split("\r")
    parsed = Mod.parse_access_reply(RpmsRpc::Reply.from_wire(lines))

    assert_equal 2, parsed[:result]
    assert_equal "***WARNING***", parsed[:messages].first
  end

  def test_parse_access_reply_nil_on_empty_or_non_integer_first_line
    assert_nil Mod.parse_access_reply(nil)
    assert_nil Mod.parse_access_reply([])
    assert_nil Mod.parse_access_reply([ "" ])
    assert_nil Mod.parse_access_reply([ "X" ])
    assert_nil Mod.parse_access_reply([ "2^990042" ])
  end

  INVALID_CHECK_ACCESS_DFNS = [ "0990031", " 990031", "990031abc", "0", "-1", 0 ].freeze

  def test_check_access_rejects_non_canonical_dfn_without_rpc
    replay
    INVALID_CHECK_ACCESS_DFNS.each do |bad_dfn|
      result = Mod.check_access(dfn: bad_dfn, generate_message: 0, option: OPTION)

      assert_equal(-1, result[:result], "dfn #{bad_dfn.inspect}")
      assert_equal 1, result[:messages].size, "dfn #{bad_dfn.inspect}"
      assert_match(/DFN/i, result[:messages].first, "dfn #{bad_dfn.inspect}")
    end
    assert_empty sent
  end

  # NOTICE^DGSEC4 (DGSEC4.m:67-84): a single value, 1 when the bulletin is filed.
  # Wire order is DFN, DGOPT, action.
  def test_record_bulletin_files_and_sends_dfn_option_and_action
    replay("bulletin")

    assert_equal({ success: true }, Mod.record_bulletin(dfn: 990_028, action: 3, option: OPTION))
    assert_equal [ [ "DG SENSITIVE RECORD BULLETIN", [ "990028", OPTION, "3" ] ] ], sent
    assert_equal [ Mod::CONTEXT, "CIAV VUECENTRIC" ], contexts
  end

  # NOTICE^DGSEC4 answers 1 for a DFN no patient has, too.
  def test_record_bulletin_answers_success_for_a_dfn_not_on_file
    replay("bulletin_not_on_file")

    assert_equal({ success: true }, Mod.record_bulletin(dfn: 999_999_999, action: 3, option: OPTION))
  end

  def test_record_bulletin_rejects_non_canonical_dfn_without_rpc
    replay
    (INVALID_CHECK_ACCESS_DFNS + [ nil, "" ]).each do |bad_dfn|
      assert_raises(ArgumentError) { Mod.record_bulletin(dfn: bad_dfn, action: 3, option: OPTION) }
    end
    assert_empty sent
  end

  # NOTICE^DGSEC4 answers 0 only when DFN or DUZ is undefined, which the gem never sends.
  def test_parse_bulletin_result_reads_the_builds_zero_as_not_filed
    raw = CapturedReplies.raw(SLUG, "bulletin_no_dfn").byteslice(2..)

    assert_equal({ success: false }, Mod.parse_bulletin_result(raw))
  end

  def test_parse_bulletin_result_nil_unless_one_or_zero
    assert_nil Mod.parse_bulletin_result("")
    assert_nil Mod.parse_bulletin_result("2")
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
end
