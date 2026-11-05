# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/client"
require "rpms_rpc/mock_client"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/ddr_fileman"
require_relative "../stock_rpcs_test_helper"

# AGG stock RPC wrappers on RpmsRpc::Agg (rpms-rpc#420). Synthetic data only.
class AggStockRpcsTest < Minitest::Test
  include StockRpcsTestHelper

  Agg = RpmsRpc::Agg
  Ddr = RpmsRpc::DdrFileman
  RS = "\x1e"
  US = "\x1f"
  DFN = "990031"

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

  # LEGL^AGGPTNAM (AGGPTNAM.m:57-104): RESULT^ERROR^RIEN header; row 1^^RIEN success.
  def test_update_legal_names_success
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}1^^42#{RS}#{US}"
    seed_global("AGG UPDATE LEGAL NAMES", DFN, wire)

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNAME" => "SYNTH" })

    assert result[:success]
    call = @mock.received_calls.find { |c| c[:rpc] == "AGG UPDATE LEGAL NAMES" }
    assert_equal Agg::CONTEXT, call[:context]
    assert_equal DFN, call[:params][0], "LEGL^AGGPTNAM: DATA is the return slot; DFN is wire param 0"
    assert_equal "A", call[:params][1]
    refute @mock.received_calls.any? { |c| c[:rpc] == "DDR GETS ENTRY DATA" },
           "add with blank RIEN must not pre-read file 9000033"
  end

  def test_update_legal_names_rejection_uses_error_piece
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}-1^Invalid parameter#{RS}#{US}"
    seed_global("AGG UPDATE LEGAL NAMES", DFN, wire)

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: {})

    refute result[:success]
    assert_match(/Invalid parameter/, result[:message])
  end

  def test_update_legal_names_is_non_idempotent_write_in_retry_safety
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(Agg, :update_legal_names)
  end

  INVALID_LEGAL_NAME_DFNS = [
    "0990031", " 990031", "990031 ", "abc", "", nil, 0, -5
  ].freeze

  INVALID_LEGAL_NAME_PROCS = [ "d", "a", "X", " D", "DELETE", nil ].freeze

  def test_update_legal_names_rejects_non_canonical_dfn_on_add_without_rpc
    INVALID_LEGAL_NAME_DFNS.each do |bad_dfn|
      @mock.received_calls.clear
      result = Agg.update_legal_names(dfn: bad_dfn, proc: "A", rien: "", params: { "AGGLNAME" => "SYNTH" })

      refute result[:success], "dfn #{bad_dfn.inspect}"
      assert_equal :invalid_dfn, result[:error], "dfn #{bad_dfn.inspect}"
      assert_no_legal_name_rpcs
    end
  end

  def test_update_legal_names_rejects_non_canonical_dfn_on_delete_without_rpc
    seed_name_patient("42", DFN)

    INVALID_LEGAL_NAME_DFNS.each do |bad_dfn|
      @mock.received_calls.clear
      result = Agg.update_legal_names(dfn: bad_dfn, proc: "D", rien: "42", params: {})

      refute result[:success], "dfn #{bad_dfn.inspect}"
      assert_equal :invalid_dfn, result[:error], "dfn #{bad_dfn.inspect}"
      assert_no_legal_name_rpcs
    end
  end

  def test_update_legal_names_rejects_invalid_proc_without_rpc
    seed_name_patient("42", DFN)

    INVALID_LEGAL_NAME_PROCS.each do |bad_proc|
      @mock.received_calls.clear
      result = Agg.update_legal_names(dfn: DFN.to_i, proc: bad_proc, rien: "42", params: {})

      refute result[:success], "proc #{bad_proc.inspect}"
      assert_equal :invalid_proc, result[:error], "proc #{bad_proc.inspect}"
      assert_no_legal_name_rpcs
    end
  end

  def test_update_legal_names_edit_proc_empty_with_rien_reads_then_legl
    seed_name_patient("42", DFN)
    seed_legl_success("42")

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "", rien: "42", params: { "AGGLNAME" => "SYNTH" })

    assert result[:success]
    assert_equal 1, ddr_calls.size
    assert_equal 1, legl_calls.size
  end

  def test_update_legal_names_ddr_read_broker_error_raises_without_legl
    error_client = Class.new(RpmsRpc::MockClient) do
      def call_rpc(rpc_name, *params)
        raise RpmsRpc::Client::RpcError, "DDR GETS ENTRY DATA: broker failure" if rpc_name == "DDR GETS ENTRY DATA"

        super
      end
    end.new
    error_client.set_authenticated("501")

    assert_raises(RpmsRpc::Client::RpcError) do
      Agg.update_legal_names(dfn: DFN.to_i, proc: "D", rien: "42", params: {}, client: error_client)
    end
    refute error_client.received_calls.any? { |c| c[:rpc] == "AGG UPDATE LEGAL NAMES" }
  end

  def test_update_legal_names_delete_verifies_rien_belongs_to_dfn_before_legl
    seed_name_patient("42", DFN)
    seed_legl_success("42")

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "D", rien: "42", params: {})

    assert result[:success]
    assert_equal 1, ddr_calls.size
    assert_equal "CIAV VUECENTRIC", ddr_calls.first[:context]
    assert_equal "9000033", ddr_calls.first[:params].first["FILE"]
    assert_equal 1, legl_calls.size
    assert_equal Agg::CONTEXT, legl_calls.first[:context]
    order = @mock.received_calls.map { |c| c[:rpc] }
    assert order.index("DDR GETS ENTRY DATA") < order.index("AGG UPDATE LEGAL NAMES")
  end

  def test_update_legal_names_refuses_rien_for_wrong_patient_without_legl
    seed_name_patient("42", "990077")

    [ "D", "A", "" ].each do |proc|
      @mock.received_calls.clear
      result = Agg.update_legal_names(dfn: DFN.to_i, proc: proc, rien: "42", params: {})

      refute_nil result
      refute result[:success]
      assert_equal :rien_not_for_dfn, result[:error]
      assert_empty legl_calls, "proc #{proc.inspect} must not call LEGL when .02 != DFN"
    end
  end

  def test_update_legal_names_read_failure_fails_closed_without_legl
    cases = [
      [ "no seed", nil ],
      [ "error marker", "[ERROR]\nRemote procedure error" ],
      [ "data without field", "[Data]" ],
      [ "empty internal", "[Data]\n9000033^42,^.02^^" ]
    ]
    cases.each do |label, text|
      @mock.received_calls.clear
      seed_gets("9000033", "42,", ".02", text) if text

      result = Agg.update_legal_names(dfn: DFN.to_i, proc: "D", rien: "42", params: {})

      refute_nil result, label
      refute result[:success], label
      assert_equal :rien_unverified, result[:error], label
      assert_empty legl_calls, label
    end
  end

  def test_update_legal_names_invalid_rien_refuses_before_any_rpc
    [ "abc", "0", "-1", "4,2", "42 " ].each do |bad_rien|
      @mock.received_calls.clear
      result = Agg.update_legal_names(dfn: DFN.to_i, proc: "D", rien: bad_rien, params: {})

      refute_nil result
      refute result[:success]
      assert_equal :invalid_rien, result[:error]
      refute @mock.received_calls.any? { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
      refute @mock.received_calls.any? { |c| c[:rpc] == "AGG UPDATE LEGAL NAMES" }
    end
  end

  def test_update_legal_names_delete_with_blank_rien_is_invalid_without_legl
    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "D", rien: "", params: {})

    refute_nil result
    refute result[:success]
    assert_equal :invalid_rien, result[:error]
    assert_empty legl_calls
  end

  def test_update_legal_names_explicit_client_routes_ddr_and_legl_through_it
    secondary = RpmsRpc::MockClient.new
    secondary.set_authenticated("501")
    key = Ddr.gets_entry_param(file: "9000033", iens: "42,", fields: ".02", flags: "I").to_s
    secondary.seed(:ddr_gets_entry_data, key, "[Data]\n9000033^42,^.02^#{DFN}^#{DFN}")
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}1^^42#{RS}#{US}"
    tables = secondary.instance_variable_get(:@lines) || {}
    tables["AGG UPDATE LEGAL NAMES"] = { DFN => wire }
    secondary.instance_variable_set(:@lines, tables)

    Agg.update_legal_names(dfn: DFN.to_i, proc: "D", rien: "42", params: {}, client: secondary)

    refute @mock.received_calls.any? { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
    refute @mock.received_calls.any? { |c| c[:rpc] == "AGG UPDATE LEGAL NAMES" }
    assert secondary.received_calls.any? { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
    assert secondary.received_calls.any? { |c| c[:rpc] == "AGG UPDATE LEGAL NAMES" }
  end

  def test_required_rpcs_lists_agg_stock_rpcs_under_agg
    assert_required_rpc(
      "AGG CHECK SENSITIVE PATIENT",
      "AGG SEND SENSITIVE NOTIFY",
      "AGG ERROR SCREEN",
      "AGG UPDATE LEGAL NAMES",
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

  def seed_gets(file, iens, fields, text, flags: "I")
    key = Ddr.gets_entry_param(file: file, iens: iens, fields: fields, flags: flags).to_s
    @mock.seed(:ddr_gets_entry_data, key, text)
  end

  def seed_name_patient(rien, patient_dfn)
    seed_gets("9000033", "#{rien},", ".02", "[Data]\n9000033^#{rien},^.02^#{patient_dfn}^#{patient_dfn}")
  end

  def seed_legl_success(rien)
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}1^^#{rien}#{RS}#{US}"
    seed_global("AGG UPDATE LEGAL NAMES", DFN, wire)
  end

  def ddr_calls
    @mock.received_calls.select { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
  end

  def legl_calls
    @mock.received_calls.select { |c| c[:rpc] == "AGG UPDATE LEGAL NAMES" }
  end

  def assert_no_legal_name_rpcs
    refute @mock.received_calls.any? { |c| c[:rpc] == "DDR GETS ENTRY DATA" },
           "DDR GETS ENTRY DATA must not run for refused input"
    refute @mock.received_calls.any? { |c| c[:rpc] == "AGG UPDATE LEGAL NAMES" },
           "AGG UPDATE LEGAL NAMES must not run for refused input"
  end

  def seed_global(rpc, key, wire)
    tables = @mock.instance_variable_get(:@lines) || {}
    tables[rpc] ||= {}
    tables[rpc][key.to_s] = wire
    @mock.instance_variable_set(:@lines, tables)
  end
end
