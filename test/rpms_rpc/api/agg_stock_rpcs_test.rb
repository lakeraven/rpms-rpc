# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/client"
require "rpms_rpc/mock_client"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/agg"
require_relative "../stock_rpcs_test_helper"

# AGG stock RPC wrappers on RpmsRpc::Agg (rpms-rpc#420). Synthetic data only.
class AggStockRpcsTest < Minitest::Test
  include StockRpcsTestHelper

  Agg = RpmsRpc::Agg
  RS = "\x1e"
  US = "\x1f"
  DFN = "990031"
  DFN_B = "990032"

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # CHK^AGGPTSEN (AGGPTSEN.m:7-33): header T00001SENSITIVE_INDICATOR, one row 0/1/2.
  def test_check_sensitive_patient_parses_indicator_row
    wire = "5\x00T00001SENSITIVE_INDICATOR#{RS}2#{RS}#{US}"
    seed_global("AGG CHECK SENSITIVE PATIENT", DFN, wire)

    result = Agg.check_sensitive_patient(dfn: DFN.to_i)

    assert_equal 2, result[:sensitive_indicator]
    call = @mock.received_calls.find { |c| c[:rpc] == "AGG CHECK SENSITIVE PATIENT" }
    assert_equal [ DFN ], call[:params]
    assert_equal Agg::CONTEXT, call[:context]
  end

  def test_check_sensitive_patient_nil_when_no_reply
    assert_nil Agg.check_sensitive_patient(dfn: 1)
  end

  def test_check_sensitive_patient_is_non_idempotent_write_in_retry_safety
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(Agg, :check_sensitive_patient)
  end

  def test_check_sensitive_patient_rejects_non_canonical_dfn_without_rpc
    [ "0990031", " 990031", "abc", "", nil, 0 ].each do |bad_dfn|
      @mock.received_calls.clear
      assert_raises(ArgumentError) { Agg.check_sensitive_patient(dfn: bad_dfn) }
      refute @mock.received_calls.any? { |c| c[:rpc] == "AGG CHECK SENSITIVE PATIENT" }, "dfn #{bad_dfn.inspect}"
    end
  end

  def test_check_sensitive_patient_rejects_non_012_indicator_rows
    %w[3 -1 01 2.0].each do |row|
      wire = "5\x00T00001SENSITIVE_INDICATOR#{RS}#{row}#{RS}#{US}"
      seed_global("AGG CHECK SENSITIVE PATIENT", DFN, wire)

      assert_nil Agg.check_sensitive_patient(dfn: DFN.to_i), "row #{row.inspect} must not coerce"
      @mock.received_calls.clear
    end

    wire = "5\x00T00001SENSITIVE_INDICATOR#{RS}#{RS}#{US}"
    seed_global("AGG CHECK SENSITIVE PATIENT", DFN, wire)
    assert_nil Agg.check_sensitive_patient(dfn: DFN.to_i), "blank row must not coerce to 0"
  end

  def test_check_sensitive_patient_accepts_only_zero_one_two
    { "0" => 0, "1" => 1, "2" => 2 }.each do |row, expected|
      wire = "5\x00T00001SENSITIVE_INDICATOR#{RS}#{row}#{RS}#{US}"
      seed_global("AGG CHECK SENSITIVE PATIENT", DFN, wire)

      result = Agg.check_sensitive_patient(dfn: DFN.to_i)
      assert_equal expected, result[:sensitive_indicator], "row #{row.inspect}"
      @mock.received_calls.clear
    end
  end

  # NOT^AGGPTSEN (AGGPTSEN.m:43-62): header I00010RESULT, row is NOTICE^DGSEC4 RESULT.
  def test_send_sensitive_notify_records_bulletin_success
    wire = "5\x00I00010RESULT#{RS}1#{RS}#{US}"
    seed_global("AGG SEND SENSITIVE NOTIFY", DFN, wire)

    result = Agg.send_sensitive_notify(dfn: DFN.to_i)

    assert result[:success]
    assert_equal Agg::CONTEXT, @mock.received_calls.last[:context]
  end

  def test_send_sensitive_notify_is_non_idempotent_write_in_retry_safety
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(Agg, :send_sensitive_notify)
  end

  def test_send_sensitive_notify_rejects_non_canonical_dfn_without_rpc
    [ "0990031", " 990031", "abc", "", nil, 0 ].each do |bad_dfn|
      @mock.received_calls.clear
      assert_raises(ArgumentError) { Agg.send_sensitive_notify(dfn: bad_dfn) }
      refute @mock.received_calls.any? { |c| c[:rpc] == "AGG SEND SENSITIVE NOTIFY" }, "dfn #{bad_dfn.inspect}"
    end
  end

  # FND^AGGEDCHK (AGGEDCHK.m:53-68): header I00010ERROR_NUM^T00030WINDOW^T00008FIELD.
  def test_error_screen_parses_header_and_error_row
    wire = "5\x00I00010ERROR_NUM^T00030WINDOW^T00008FIELD#{RS}37^REG^AGGPTLNM#{RS}#{US}"
    seed_global("AGG ERROR SCREEN", "37", wire)

    rows = Agg.error_screen(errnum: "37")

    assert_equal 1, rows.size
    assert_equal "37", rows.first[:error_num]
    assert_equal "REG", rows.first[:window]
    assert_equal "AGGPTLNM", rows.first[:field]
  end

  def test_error_screen_empty_errnum_lists_all_errors
    wire = "5\x00I00010ERROR_NUM^T00030WINDOW^T00008FIELD#{RS}#{US}"
    seed_global("AGG ERROR SCREEN", "", wire)

    assert_equal [], Agg.error_screen(errnum: "")
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

  # Supplement AGG PATIENT EDIT CHECK: AGGRPC bind (CHK^AGGEDCHK, AGGEDCHK.m:5).
  def test_edit_check_binds_aggrpc
    @mock.seed(:agg_patient_edit_check, DFN,
      "I00010HIDE_ERROR_NUM^T00030MSG^T00001TYPE#{RS}#{US}")

    Agg.edit_check(dfn: DFN.to_i)

    call = @mock.received_calls.find { |c| c[:rpc] == "AGG PATIENT EDIT CHECK" }
    assert_equal Agg::CONTEXT, call[:context]
  end

  private

  def seed_global(rpc, key, wire)
    tables = @mock.instance_variable_get(:@lines) || {}
    tables[rpc] ||= {}
    tables[rpc][key.to_s] = wire
    @mock.instance_variable_set(:@lines, tables)
  end
end
