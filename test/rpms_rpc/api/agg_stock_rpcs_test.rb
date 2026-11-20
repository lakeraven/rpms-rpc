# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/agg"
require_relative "../captured_replies"
require_relative "../stock_rpcs_test_helper"

# AGG stock RPC wrappers on RpmsRpc::Agg (rpms-rpc#420). Each test replays a
# call the gem made as PROFILE,REG on a throwaway container where DFN 990028
# was made a sensitive record (test/fixtures/captured_replies/agg-stock.yml).
class AggStockRpcsTest < Minitest::Test
  include StockRpcsTestHelper

  Agg = RpmsRpc::Agg
  SLUG = "agg-stock"
  BAD_DFNS = [ "0990031", " 990031", "abc", "", nil, 0 ].freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow = nil)
    @client = CapturedReplies::ReplayCiaClient.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {})
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
  def contexts = @client.calls.select { |c| c[:rpc] == :create_context }.map { |c| c[:params].first }

  # CHK^AGGPTSEN (AGGPTSEN.m:7-33): header T00001SENSITIVE_INDICATOR, one row 0/1/2.
  def test_check_sensitive_patient_reads_the_indicator_under_aggrpc
    replay("sensitive")

    assert_equal({ sensitive_indicator: 2 }, Agg.check_sensitive_patient(dfn: 990_028))
    assert_equal [ [ "AGG CHECK SENSITIVE PATIENT", [ "990028" ] ] ], sent
    assert_equal [ Agg::CONTEXT, "CIAV VUECENTRIC" ], contexts
  end

  def test_check_sensitive_patient_reads_zero_for_a_record_that_is_not_sensitive
    replay("not_sensitive")

    assert_equal({ sensitive_indicator: 0 }, Agg.check_sensitive_patient(dfn: "990031"))
  end

  # CHK^AGGPTSEN answers 0 for a DFN no patient has: "not sensitive" is not "on file".
  def test_check_sensitive_patient_reads_zero_for_a_dfn_not_on_file
    replay("not_on_file")

    assert_equal({ sensitive_indicator: 0 }, Agg.check_sensitive_patient(dfn: 999_999_999))
  end

  def test_check_sensitive_patient_rejects_non_canonical_dfn_without_rpc
    replay
    BAD_DFNS.each { |bad| assert_raises(ArgumentError, "dfn #{bad.inspect}") { Agg.check_sensitive_patient(dfn: bad) } }
    assert_empty sent
  end

  def test_check_sensitive_patient_is_non_idempotent_write_in_retry_safety
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(Agg, :check_sensitive_patient)
  end

  # NOT^AGGPTSEN (AGGPTSEN.m:43-62): header I00010RESULT, row is NOTICE^DGSEC4's RESULT.
  def test_send_sensitive_notify_records_bulletin_success
    replay("notify")

    assert_equal({ success: true }, Agg.send_sensitive_notify(dfn: 990_028))
    assert_equal [ [ "AGG SEND SENSITIVE NOTIFY", [ "990028" ] ] ], sent
    assert_equal [ Agg::CONTEXT, "CIAV VUECENTRIC" ], contexts
  end

  # NOTICE^DGSEC4 answers 1 for a DFN no patient has, too.
  def test_send_sensitive_notify_answers_success_for_a_dfn_not_on_file
    replay("notify_not_on_file")

    assert_equal({ success: true }, Agg.send_sensitive_notify(dfn: 999_999_999))
  end

  def test_send_sensitive_notify_rejects_non_canonical_dfn_without_rpc
    replay
    BAD_DFNS.each { |bad| assert_raises(ArgumentError, "dfn #{bad.inspect}") { Agg.send_sensitive_notify(dfn: bad) } }
    assert_empty sent
  end

  def test_send_sensitive_notify_is_non_idempotent_write_in_retry_safety
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(Agg, :send_sensitive_notify)
  end

  # FND^AGGEDCHK (AGGEDCHK.m:53-68) writes its header and then no row, for an
  # error number on file (37) and for all of them: FER's row write is commented
  # out in the stock routine.
  def test_error_screen_reads_the_builds_header_only_reply_as_no_rows
    replay("error_screen_one")
    assert_equal [], Agg.error_screen(errnum: "37")
    assert_equal [ [ "AGG ERROR SCREEN", [ "37" ] ] ], sent

    replay("error_screen_all")
    assert_equal [], Agg.error_screen(errnum: "")
    assert_equal [ [ "AGG ERROR SCREEN", [ "" ] ] ], sent
  end

  # Supplement AGG PATIENT EDIT CHECK: AGGRPC bind (CHK^AGGEDCHK, AGGEDCHK.m:5).
  def test_edit_check_binds_aggrpc
    replay("edit_check")

    checks = Agg.edit_check(dfn: 990_031)[:checks]

    assert_equal "37", checks.first[:hide_error_num]
    assert_equal "INTERNET ACCESS INFORMATION PAST ONE YEAR", checks.first[:msg]
    assert_equal [ [ "AGG PATIENT EDIT CHECK", [ "990031" ] ] ], sent
    assert_equal [ Agg::CONTEXT, "CIAV VUECENTRIC" ], contexts
  end

  def test_required_rpcs_lists_agg_stock_rpcs_under_agg
    assert_required_rpc(
      "AGG CHECK SENSITIVE PATIENT",
      "AGG SEND SENSITIVE NOTIFY",
      "AGG ERROR SCREEN",
      "AGG PATIENT EDIT CHECK",
      under: "RpmsRpc::Agg"
    )
  end
end
