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
  DFN_B = "990032"
  SERVER_TODAY_FM = 3261105

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
    seed_blank_add_prechecks(server_today: SERVER_TODAY_FM, max_ien: 41)
    seed_legl_success("42")

    result = Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }
    )

    assert result[:success], result.inspect
    assert_equal 42, result[:ien]
    assert_equal 2, orwu_dt_calls.size
    assert_equal [ "T", "" ], orwu_dt_calls[0][:params]
    assert_equal [ "11/05/2026", "TS" ], orwu_dt_calls[1][:params]
    assert(orwu_dt_calls.all? { |c| c[:context] == "CIAV VUECENTRIC" })
    assert_equal 1, b_index_lister_calls.size
    assert_equal SERVER_TODAY_FM, b_index_lister_days_from_calls.first
    assert_equal 1, max_ien_lister_calls.size
    assert_equal 1, lock_calls.size
    assert_equal legal_name_b_lock_param(SERVER_TODAY_FM), lock_calls.first[:params].first
    assert_equal "CIAV VUECENTRIC", lock_calls.first[:context]
    assert_equal 1, unlock_calls.size
    assert_equal legal_name_b_unlock_param(SERVER_TODAY_FM), unlock_calls.first[:params].first
    call = legl_calls.first
    assert_equal Agg::CONTEXT, call[:context]
    assert_equal DFN, call[:params][0]
    assert_equal "A", call[:params][1]
    assert_equal "", call[:params][2]
    assert_equal "AGGLNDTC=11/05/2026#{Agg::PARM_DELIM}AGGLNMC=SYNTH", call[:params][3]
    assert_equal 1, ddr_calls.size, "post-check .01;.02 read"
    assert_equal ".01;.02", ddr_calls.first[:params].first["FIELDS"]
    assert_equal "CIAV VUECENTRIC", ddr_calls.first[:context]
    order = @mock.received_calls.map { |c| c[:rpc] }
    assert order.index("DDR LOCK/UNLOCK NODE") < order.index("DDR LISTER")
    assert order.index("AGG UPDATE LEGAL NAMES") < order.rindex("DDR LOCK/UNLOCK NODE")
  end

  def test_update_legal_names_rejection_uses_error_piece
    seed_blank_add_prechecks(server_today: SERVER_TODAY_FM, max_ien: 41)
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}-1^Invalid parameter#{RS}#{US}"
    seed_global("AGG UPDATE LEGAL NAMES", DFN, wire)

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: {})

    refute result[:success]
    assert_equal :agg_rejected, result[:error]
    assert_match(/Invalid parameter/, result[:message])
    assert_empty ddr_calls, "LEGL rejection must not run post-check DDR GETS ENTRY DATA"
    # M2: the rejection is not proof nothing was filed, so the B index is
    # re-read under the lock; a clear re-read leaves written unclaimed.
    assert_equal 2, b_index_lister_calls.size, "B index re-read after a LEGL -1 reply"
    refute_includes [ true, :unknown ], result[:written]
  end

  def test_update_legal_names_blank_add_legl_rejection_with_entry_now_present_reports_written
    seed_blank_add_prechecks(server_today: SERVER_TODAY_FM, max_ien: 41)
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}-1^Invalid parameter#{RS}#{US}"
    seed_global("AGG UPDATE LEGAL NAMES", DFN, wire)
    client = b_reread_client([ "[Data]\n", "[Data]\n77^#{SERVER_TODAY_FM}" ])
    seed_legl_rejection_prechecks_on(client, wire)

    result = Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }, client: client
    )

    refute result[:success]
    assert_equal true, result[:written], result.inspect
    assert_equal 2, client.b_reads
    order = client.received_calls.map { |c| c[:rpc] }
    reread_idx = client.b_read_positions.last
    assert_operator reread_idx, :<, order.rindex("DDR LOCK/UNLOCK NODE"), "re-read happens before unlock"
  end

  def test_update_legal_names_blank_add_legl_rejection_with_failed_reread_reports_written_unknown
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}-1^Invalid parameter#{RS}#{US}"
    [ RpmsRpc::Client::RpcError.new("boom"), RpmsRpc::Client::ConnectionError.new("lost"),
      RpmsRpc::Client::TimeoutError.new("slow"), "[BEGIN_diDATA]\n" ].each do |second|
      client = b_reread_client([ "[Data]\n", second ])
      seed_legl_rejection_prechecks_on(client, wire)

      result = Agg.update_legal_names(
        dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }, client: client
      )

      refute result[:success], second.inspect
      assert_equal :unknown, result[:written], "#{second.inspect}: #{result.inspect}"
      unlocks = client.received_calls.select do |c|
        c[:rpc] == "DDR LOCK/UNLOCK NODE" && !c[:params].first.key?("LOCKMODE")
      end
      assert_equal 1, unlocks.size, second.inspect
    end
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
      result = Agg.update_legal_names(dfn: bad_dfn, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

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

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "", rien: "42", params: { "AGGLNMC" => "SYNTH" })

    assert result[:success]
    assert_equal 1, ddr_calls.size
    assert_equal 1, legl_calls.size
    refute @mock.received_calls.any? { |c| c[:rpc] == "ORWU DT" },
           "non-blank RIEN edit must not run server-today ORWU DT"
    refute @mock.received_calls.any? { |c| c[:rpc] == "DDR LISTER" },
           "non-blank RIEN edit must not run legal-name B or max-IEN listers"
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

  # --- update_legal_names blank-RIEN add guards (rpms-rpc#420 / PR #605) ---

  def test_update_legal_names_rejects_non_hash_params_without_any_rpc
    [ [], "SYNTH", 7 ].each do |bad_params|
      @mock.received_calls.clear
      result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: bad_params)

      refute_nil result, bad_params.inspect
      refute result[:success], bad_params.inspect
      assert_equal :invalid_param, result[:error], bad_params.inspect
      assert_no_legal_name_rpcs
      refute @mock.received_calls.any? { |c| c[:rpc] == "ORWU DT" }, bad_params.inspect
    end
  end

  def test_update_legal_names_rejects_duplicate_param_keys_with_same_name_without_any_rpc
    @mock.received_calls.clear
    result = Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "",
      params: { "AGGLNDTC" => "T", AGGLNDTC: "11/01/2026", "AGGLNMC" => "SYNTH" }
    )

    refute_nil result
    refute result[:success]
    assert_equal :invalid_param, result[:error]
    assert_no_legal_name_rpcs
    refute @mock.received_calls.any? { |c| c[:rpc] == "ORWU DT" }
  end

  def test_update_legal_names_rejects_disallowed_param_keys_without_any_rpc
    [
      [ { "RIEN" => "77" }, "RIEN" ],
      [ { "DFN" => DFN_B }, "DFN" ],
      [ { "AGGLNAME" => "SYNTH" }, "AGGLNAME" ],
      [ { RIEN: "77" }, "RIEN" ],
      [ { "aggldtc" => "3261105" }, "aggldtc" ]
    ].each do |params, name_in_message|
      @mock.received_calls.clear
      result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: params)

      refute_nil result, params.inspect
      refute result[:success], params.inspect
      assert_equal :invalid_param, result[:error], params.inspect
      assert_includes result[:message].to_s, name_in_message, params.inspect
      assert_no_legal_name_rpcs
      refute @mock.received_calls.any? { |c| c[:rpc] == "ORWU DT" }, params.inspect
    end
  end

  def test_update_legal_names_blank_add_refuses_unverified_server_today_orwu_reply
    [ nil, "-1", "3261105.12", "abc" ].each do |bad|
      @mock.received_calls.clear
      @mock.seed_scalar(:orwu_dt, "T", bad) if bad
      result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

      refute_nil result
      refute result[:success]
      assert_equal :legal_name_unverified, result[:error]
      assert_empty legl_calls
      assert_empty lock_calls
    end
  end

  def test_update_legal_names_blank_add_refuses_invalid_caller_agglndtc_without_orwu
    bad_values = [ "T", "NOW", "11/01/2026@1200", "3261105:1430", "13/01/2026", "02/30/2026" ]
    bad_values.each do |agglndtc|
      @mock.received_calls.clear
      result = Agg.update_legal_names(
        dfn: DFN.to_i, proc: "A", rien: "",
        params: { "AGGLNMC" => "SYNTH", "AGGLNDTC" => agglndtc }
      )

      refute_nil result, agglndtc.inspect
      refute result[:success], agglndtc.inspect
      assert_equal :legal_name_unverified, result[:error], agglndtc.inspect
      assert_empty legl_calls, agglndtc.inspect
      refute @mock.received_calls.any? { |c| c[:rpc] == "ORWU DT" }, agglndtc.inspect
    end
  end

  def test_update_legal_names_blank_add_refuses_when_orwu_ts_reply_does_not_match_day
    seed_legal_name_lock(SERVER_TODAY_FM)
    @mock.seed_scalar(:orwu_dt, "T", SERVER_TODAY_FM.to_s)
    @mock.seed_scalar(:orwu_dt, "11/05/2026", "3261106")

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert_empty legl_calls
    assert_empty lock_calls
    assert_equal 2, orwu_dt_calls.size
  end

  def test_update_legal_names_blank_add_refuses_when_lock_not_acquired
    seed_blank_add_server_today_flow(SERVER_TODAY_FM)
    seed_b_lister(day: fileman_prior_calendar_day(SERVER_TODAY_FM), text: "[Data]\n")
    seed_b_lister(day: SERVER_TODAY_FM, text: "[Data]\n")
    seed_max_ien_lister("[Data]\n41")
    seed_legal_name_lock(SERVER_TODAY_FM, acquired: false)

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    assert result.is_a?(Hash), "expected a refusal hash, got #{result.inspect}"
    refute result[:success]
    assert_equal :legal_name_busy, result[:error]
    assert_empty b_index_lister_calls
    assert_empty legl_calls
    assert_equal 1, lock_calls.size
    assert_empty unlock_calls
  end

  def test_update_legal_names_blank_add_refuses_when_b_index_row_occupies_server_today
    seed_blank_add_server_today_flow(SERVER_TODAY_FM)
    seed_legal_name_lock(SERVER_TODAY_FM)
    seed_legal_name_unlock(SERVER_TODAY_FM)
    seed_b_lister(day: fileman_prior_calendar_day(SERVER_TODAY_FM), text: "[Data]\n")
    seed_b_lister(day: SERVER_TODAY_FM, text: "[Data]\n55^#{SERVER_TODAY_FM}")

    result = Agg.update_legal_names(
      dfn: DFN_B.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }
    )

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_date_taken, result[:error]
    assert_match(/3261105/, result[:message].to_s)
    assert_empty legl_calls
    assert_equal 1, unlock_calls.size
  end

  def test_update_legal_names_blank_add_refuses_when_b_index_row_has_time_on_server_today
    seed_blank_add_server_today_flow(SERVER_TODAY_FM)
    seed_legal_name_lock(SERVER_TODAY_FM)
    seed_legal_name_unlock(SERVER_TODAY_FM)
    seed_b_lister(day: fileman_prior_calendar_day(SERVER_TODAY_FM), text: "[Data]\n")
    seed_b_lister(day: SERVER_TODAY_FM, text: "[Data]\n55^#{SERVER_TODAY_FM}.143")

    result = Agg.update_legal_names(
      dfn: DFN_B.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }
    )

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_date_taken, result[:error]
    assert_empty legl_calls
    assert_equal 1, unlock_calls.size
  end

  def test_update_legal_names_blank_add_allows_when_b_index_row_only_on_prior_calendar_day
    prior = fileman_prior_calendar_day(SERVER_TODAY_FM)
    seed_blank_add_server_today_flow(SERVER_TODAY_FM)
    seed_legal_name_lock(SERVER_TODAY_FM)
    seed_legal_name_unlock(SERVER_TODAY_FM)
    seed_b_lister(day: SERVER_TODAY_FM, text: "[Data]\n")
    seed_b_lister(day: prior, text: "[Data]\n55^#{prior}")
    seed_max_ien_lister("[Data]\n41")
    seed_legl_success("42", dfn: DFN_B)

    result = Agg.update_legal_names(
      dfn: DFN_B.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }
    )

    assert result[:success], result.inspect
    assert_equal 42, result[:ien]
    assert_equal 1, b_index_lister_calls.size
    assert_equal SERVER_TODAY_FM, b_index_lister_days_from_calls.first
  end

  def test_update_legal_names_blank_add_refuses_agglndtc_with_colon_without_legl
    result = Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "",
      params: { "AGGLNMC" => "SYNTH", "AGGLNDTC" => "3261105:143000" }
    )

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert_empty legl_calls
    refute @mock.received_calls.any? { |c| c[:rpc] == "ORWU DT" }
  end

  def test_update_legal_names_blank_add_reports_takeover_when_legl_rien_equals_prior_max
    seed_blank_add_prechecks(server_today: SERVER_TODAY_FM, max_ien: 60)
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}1^^60#{RS}#{US}"
    seed_global("AGG UPDATE LEGAL NAMES", DFN_B, wire)

    result = Agg.update_legal_names(dfn: DFN_B.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_takeover, result[:error]
    assert_equal 60, result[:ien]
    assert result[:written]
    assert_equal 1, unlock_calls.size
  end

  def test_update_legal_names_blank_add_reports_takeover_when_legl_returns_existing_ien
    seed_blank_add_prechecks(server_today: SERVER_TODAY_FM, max_ien: 60)
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}1^^55#{RS}#{US}"
    seed_global("AGG UPDATE LEGAL NAMES", DFN_B, wire)

    result = Agg.update_legal_names(dfn: DFN_B.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_takeover, result[:error]
    assert_equal 55, result[:ien]
    assert result[:written]
    assert_match(/already existed/i, result[:message].to_s)
  end

  def test_update_legal_names_blank_add_reports_takeover_when_post_check_dfn_mismatch
    seed_blank_add_prechecks(server_today: SERVER_TODAY_FM, max_ien: 41)
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}1^^55#{RS}#{US}"
    seed_global("AGG UPDATE LEGAL NAMES", DFN_B, wire)
    seed_legal_name_post_check("55", DFN)

    result = Agg.update_legal_names(dfn: DFN_B.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_takeover, result[:error]
    assert_equal 55, result[:ien]
    assert result[:written]
  end

  def test_update_legal_names_blank_add_unverified_when_legl_succeeds_without_rien
    seed_blank_add_prechecks(server_today: SERVER_TODAY_FM, max_ien: 41)
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}1^^#{RS}#{US}"
    seed_global("AGG UPDATE LEGAL NAMES", DFN_B, wire)

    result = Agg.update_legal_names(dfn: DFN_B.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert result[:written]
  end

  def test_update_legal_names_blank_add_unverified_when_b_lister_reply_unreadable
    seed_blank_add_server_today_flow(SERVER_TODAY_FM)
    seed_legal_name_lock(SERVER_TODAY_FM)
    seed_legal_name_unlock(SERVER_TODAY_FM)
    seed_b_lister(day: fileman_prior_calendar_day(SERVER_TODAY_FM), text: "[Data]\n")
    seed_b_lister(day: SERVER_TODAY_FM, text: "SYNTHETIC BROKER NOISE")
    seed_max_ien_lister("[Data]\n60")

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert_empty legl_calls
    assert_equal 1, unlock_calls.size
  end

  def test_update_legal_names_blank_add_unverified_when_b_first_row_missing_date_piece
    seed_blank_add_server_today_flow(SERVER_TODAY_FM)
    seed_legal_name_lock(SERVER_TODAY_FM)
    seed_legal_name_unlock(SERVER_TODAY_FM)
    seed_b_lister(day: fileman_prior_calendar_day(SERVER_TODAY_FM), text: "[Data]\n")
    seed_b_lister(day: SERVER_TODAY_FM, text: "[Data]\n55^")
    seed_max_ien_lister("[Data]\n41")

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert_empty legl_calls
    assert_equal 1, unlock_calls.size
  end

  def test_update_legal_names_blank_add_unverified_when_b_first_row_ien_not_numeric
    seed_blank_add_server_today_flow(SERVER_TODAY_FM)
    seed_legal_name_lock(SERVER_TODAY_FM)
    seed_legal_name_unlock(SERVER_TODAY_FM)
    seed_b_lister(day: fileman_prior_calendar_day(SERVER_TODAY_FM), text: "[Data]\n")
    seed_b_lister(day: SERVER_TODAY_FM, text: "[Data]\nX^3261105")
    seed_max_ien_lister("[Data]\n41")

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert_empty legl_calls
    assert_equal 1, unlock_calls.size
  end

  def test_update_legal_names_blank_add_unverified_when_b_lister_v1_reply_truncated
    seed_blank_add_server_today_flow(SERVER_TODAY_FM)
    seed_legal_name_lock(SERVER_TODAY_FM)
    seed_legal_name_unlock(SERVER_TODAY_FM)
    seed_b_lister(day: fileman_prior_calendar_day(SERVER_TODAY_FM), text: "[Data]\n")
    seed_b_lister(day: SERVER_TODAY_FM, text: "[BEGIN_diDATA]\n")
    seed_max_ien_lister("[Data]\n41")

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert_empty legl_calls
    assert_equal 1, unlock_calls.size
  end

  def test_update_legal_names_blank_add_agglndtc_orwu_converts_then_checks_one_b_day
    day = 3_261_101
    seed_legal_name_lock(day)
    seed_legal_name_unlock(day)
    @mock.seed_scalar(:orwu_dt, "T", SERVER_TODAY_FM.to_s)
    @mock.seed_scalar(:orwu_dt, "11/01/2026", day.to_s)
    seed_b_lister(day: fileman_prior_calendar_day(day), text: "[Data]\n")
    seed_b_lister(day: day, text: "[Data]\n70^3261101")
    seed_b_lister(day: fileman_prior_calendar_day(SERVER_TODAY_FM), text: "[Data]\n")
    seed_b_lister(day: SERVER_TODAY_FM, text: "[Data]\n")
    seed_max_ien_lister("[Data]\n41")

    result = Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "",
      params: { "AGGLNMC" => "SYNTH", "AGGLNDTC" => "11/01/2026" }
    )

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_date_taken, result[:error]
    assert_match(/3261101/, result[:message].to_s)
    assert_empty legl_calls
    assert_equal 1, orwu_dt_calls.size
    assert_equal [ "11/01/2026", "TS" ], orwu_dt_calls.first[:params]
    assert(orwu_dt_calls.all? { |c| c[:context] == "CIAV VUECENTRIC" })
    assert_equal [ day ], b_index_lister_days_from_calls
    from = b_index_lister_calls.first[:params].first["FROM"]
    assert_equal "#{day - 1}.9999999", from
    assert_equal 1, unlock_calls.size
  end

  def test_update_legal_names_blank_add_refuses_agglndtc_when_orwu_ts_returns_minus_one
    @mock.seed_scalar(:orwu_dt, "11/05/2026", "-1")

    result = Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "",
      params: { "AGGLNMC" => "SYNTH", "AGGLNDTC" => "11/05/2026" }
    )

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert_empty legl_calls
    assert_equal 1, orwu_dt_calls.size
    assert_equal [ "11/05/2026", "TS" ], orwu_dt_calls.first[:params]
  end

  def test_update_legal_names_blank_add_agglndtc_orwu_non_fileman_reply_unverified
    @mock.seed_scalar(:orwu_dt, "11/01/2026", "abc")

    result = Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "",
      params: { "AGGLNMC" => "SYNTH", "AGGLNDTC" => "11/01/2026" }
    )

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert_empty legl_calls
    assert_empty lock_calls
  end

  # FROM is the numeric predecessor of the day, never the prior calendar day:
  # 3270100 sorts between 3261231 and 3270101 and would hide nothing, but
  # 3261231.9999999 would skip an imprecise-date row at 3270100 (M1).
  def test_update_legal_names_blank_add_b_from_is_numeric_predecessor_at_month_boundary
    day = 3_270_101
    from = "3270100.9999999"
    seed_legal_name_lock(day)
    seed_legal_name_unlock(day)
    @mock.seed_scalar(:orwu_dt, "01/01/2027", day.to_s)
    seed_b_lister(day: day, text: "[Data]\n", from: from)
    seed_max_ien_lister("[Data]\n41")

    Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "",
      params: { "AGGLNMC" => "SYNTH", "AGGLNDTC" => "01/01/2027" }
    )

    assert_equal 1, b_index_lister_calls.size
    assert_equal from, b_index_lister_calls.first[:params].first["FROM"]
    assert_equal 1, orwu_dt_calls.size
    assert_equal [ "01/01/2027", "TS" ], orwu_dt_calls.first[:params]
  end

  def test_update_legal_names_blank_add_b_from_is_numeric_predecessor_mid_month
    day = 3_261_101
    seed_legal_name_lock(day)
    seed_legal_name_unlock(day)
    @mock.seed_scalar(:orwu_dt, "11/01/2026", day.to_s)
    seed_b_lister(day: day, text: "[Data]\n", from: "3261100.9999999")
    seed_max_ien_lister("[Data]\n41")
    seed_legl_success("42", day_fm: day)

    Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "",
      params: { "AGGLNMC" => "SYNTH", "AGGLNDTC" => "11/01/2026" }
    )

    assert_equal "3261100.9999999", b_index_lister_calls.first[:params].first["FROM"]
  end

  # M1: an imprecise-date row (3261100 = NOV 2026) sorts between the prior
  # calendar day and the requested day. When the B read comes back with that
  # row for requested 3261101, an exact 3261101 entry may sit behind it, so
  # the add must be refused (taken or unverified), nothing written.
  def test_update_legal_names_blank_add_refuses_when_imprecise_date_row_returned_for_requested_day
    day = 3_261_101
    seed_legal_name_lock(day)
    seed_legal_name_unlock(day)
    @mock.seed_scalar(:orwu_dt, "11/01/2026", day.to_s)
    [ "3261100.9999999", "3261031.9999999", "3261100" ].each do |from|
      seed_b_lister(day: day, text: "[Data]\n55^3261100", from: from)
    end
    seed_max_ien_lister("[Data]\n41")
    seed_legl_success("42", day_fm: day)

    result = Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH", "AGGLNDTC" => "11/01/2026" }
    )

    refute_nil result
    refute result[:success], result.inspect
    assert_includes %i[legal_name_date_taken legal_name_unverified], result[:error]
    assert_empty legl_calls
    refute result[:written]
    assert_equal 1, unlock_calls.size
  end

  def test_update_legal_names_blank_add_v1_empty_di_data_is_clear_for_b_and_max
    seed_blank_add_server_today_flow(SERVER_TODAY_FM)
    seed_legal_name_lock(SERVER_TODAY_FM)
    seed_legal_name_unlock(SERVER_TODAY_FM)
    empty_v1 = "[BEGIN_diDATA]\n[END_diDATA]"
    seed_b_lister(day: fileman_prior_calendar_day(SERVER_TODAY_FM), text: empty_v1)
    seed_b_lister(day: SERVER_TODAY_FM, text: empty_v1)
    seed_max_ien_lister(empty_v1)
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}1^^1#{RS}#{US}"
    seed_global("AGG UPDATE LEGAL NAMES", DFN, wire)
    seed_legal_name_post_check("1", DFN)

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    assert result[:success], result.inspect
    assert_equal 1, result[:ien]
  end

  def test_update_legal_names_blank_add_unverified_when_max_ien_lister_v1_reply_truncated
    seed_blank_add_server_today_flow(SERVER_TODAY_FM)
    seed_legal_name_lock(SERVER_TODAY_FM)
    seed_legal_name_unlock(SERVER_TODAY_FM)
    seed_b_lister(day: fileman_prior_calendar_day(SERVER_TODAY_FM), text: "[Data]\n")
    seed_b_lister(day: SERVER_TODAY_FM, text: "[Data]\n")
    seed_max_ien_lister("[BEGIN_diDATA]\n")

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert_empty legl_calls
    assert_equal 1, unlock_calls.size
  end

  def test_update_legal_names_blank_add_ddr_read_broker_error_unlocks_and_raises
    error_client = Class.new(RpmsRpc::MockClient) do
      def call_rpc(rpc_name, *params)
        if rpc_name == "DDR LISTER" && params.first.is_a?(Hash) && params.first["XREF"] == "B"
          raise RpmsRpc::Client::RpcError, "DDR LISTER: broker failure"
        end

        super
      end
    end.new
    error_client.set_authenticated("501")
    seed_blank_add_server_today_flow_on(error_client, SERVER_TODAY_FM)
    seed_legal_name_lock_on(error_client, SERVER_TODAY_FM)
    seed_legal_name_unlock_on(error_client, SERVER_TODAY_FM)
    seed_b_lister_on(error_client, day: fileman_prior_calendar_day(SERVER_TODAY_FM), text: "[Data]\n")
    seed_b_lister_on(error_client, day: SERVER_TODAY_FM, text: "[Data]\n")
    error_client.seed(:ddr_lister, max_ien_lister_param.to_s, "[Data]\n41")

    assert_raises(RpmsRpc::Client::RpcError) do
      Agg.update_legal_names(
        dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }, client: error_client
      )
    end
    refute error_client.received_calls.any? { |c| c[:rpc] == "AGG UPDATE LEGAL NAMES" }
    unlocks = error_client.received_calls.select do |c|
      c[:rpc] == "DDR LOCK/UNLOCK NODE" && !c[:params].first.key?("LOCKMODE")
    end
    assert_equal 1, unlocks.size
  end

  def test_update_legal_names_blank_add_allows_b_lister_first_row_on_later_day
    seed_blank_add_prechecks(server_today: SERVER_TODAY_FM, max_ien: 41)
    seed_b_lister(day: SERVER_TODAY_FM, text: "[Data]\n80^3261106")
    seed_legl_success("42")

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    assert result[:success], result.inspect
    assert_equal 42, result[:ien]
    assert_equal 1, legl_calls.size
  end

  def test_update_legal_names_blank_add_empty_max_ien_file_allows_first_rien
    seed_blank_add_prechecks(server_today: SERVER_TODAY_FM, max_ien: 0)
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}1^^1#{RS}#{US}"
    seed_global("AGG UPDATE LEGAL NAMES", DFN, wire)
    seed_legal_name_post_check("1", DFN)

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    assert result[:success], result.inspect
    assert_equal 1, result[:ien]
  end

  def test_update_legal_names_blank_add_unverified_when_max_ien_lister_first_ien_non_numeric
    seed_blank_add_server_today_flow(SERVER_TODAY_FM)
    seed_legal_name_lock(SERVER_TODAY_FM)
    seed_legal_name_unlock(SERVER_TODAY_FM)
    seed_b_lister(day: fileman_prior_calendar_day(SERVER_TODAY_FM), text: "[Data]\n")
    seed_b_lister(day: SERVER_TODAY_FM, text: "[Data]\n")
    seed_max_ien_lister("[Data]\nX^")

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert_empty legl_calls
    assert_equal 1, unlock_calls.size
  end

  def test_update_legal_names_blank_add_caller_agglndtc_is_first_on_wire
    day = 3_261_101
    seed_legal_name_lock(day)
    seed_legal_name_unlock(day)
    @mock.seed_scalar(:orwu_dt, "11/01/2026", day.to_s)
    seed_b_lister(day: fileman_prior_calendar_day(day), text: "[Data]\n")
    seed_b_lister(day: day, text: "[Data]\n")
    seed_max_ien_lister("[Data]\n41")
    seed_legl_success("42", day_fm: day)

    result = Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "",
      params: { "AGGLNMC" => "SYNTH", "AGGLNDTC" => "11/01/2026" }
    )

    assert result[:success], result.inspect
    assert_equal "AGGLNDTC=11/01/2026#{Agg::PARM_DELIM}AGGLNMC=SYNTH", legl_calls.first[:params][3]
  end

  def test_update_legal_names_blank_add_drops_blank_caller_agglndtc_and_files_server_today_first
    seed_blank_add_prechecks(server_today: SERVER_TODAY_FM, max_ien: 41)
    seed_legl_success("42")

    result = Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "",
      params: { "AGGLNDTC" => "", "AGGLNMC" => "SYNTH" }
    )

    assert result[:success], result.inspect
    wire = legl_calls.first[:params][3]
    assert_equal "AGGLNDTC=11/05/2026#{Agg::PARM_DELIM}AGGLNMC=SYNTH", wire
    refute wire.match?(/AGGLNDTC=\s*#{Regexp.escape(Agg::PARM_DELIM)}/)
  end

  def test_update_legal_names_blank_add_post_check_date_mismatch_reports_written
    seed_blank_add_prechecks(server_today: SERVER_TODAY_FM, max_ien: 41)
    seed_legl_success("42", post_check: false)
    seed_legal_name_post_check("42", DFN, day_fm: 3_261_106)

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    refute result[:success]
    assert_equal :legal_name_date_mismatch, result[:error]
    assert_equal 42, result[:ien]
    assert result[:written]
    assert_equal 1, unlock_calls.size
  end

  def test_update_legal_names_blank_add_post_check_missing_field_unverified_written
    seed_blank_add_prechecks(server_today: SERVER_TODAY_FM, max_ien: 41)
    seed_legl_success("42", post_check: false)
    seed_gets("9000033", "42,", ".01;.02", "[Data]\n9000033^42,^.02^#{DFN}^#{DFN}")

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert_equal 42, result[:ien]
    assert result[:written]
    assert_equal 1, unlock_calls.size
  end

  def test_update_legal_names_blank_add_post_check_ddr_error_unverified_written_unlocks
    client = legal_name_post_check_error_client
    client.set_authenticated("501")
    seed_blank_add_prechecks_on(client, server_today: SERVER_TODAY_FM, max_ien: 41)
    seed_legl_success_on(client, "42")

    result = Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }, client: client
    )

    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert_equal 42, result[:ien]
    assert result[:written]
    unlocks = client.received_calls.select do |c|
      c[:rpc] == "DDR LOCK/UNLOCK NODE" && !c[:params].first.key?("LOCKMODE")
    end
    assert_equal 1, unlocks.size
  end

  def test_update_legal_names_blank_add_nil_legl_reply_unverified_written_unlocks
    seed_blank_add_prechecks(server_today: SERVER_TODAY_FM, max_ien: 41)

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert result[:written]
    refute result.key?(:ien)
    assert_equal 1, unlock_calls.size
  end

  def test_update_legal_names_blank_add_lock_reply_not_one_is_busy_without_b_read_or_unlock
    seed_blank_add_server_today_flow(SERVER_TODAY_FM)
    cases = [
      [ "no seed", nil ],
      [ "empty", "" ],
      [ "garbage", "garbage" ]
    ]
    cases.each do |label, lock_reply|
      @mock.received_calls.clear
      lock_param = legal_name_b_lock_param(SERVER_TODAY_FM).to_s
      scalars = @mock.instance_variable_get(:@scalars)
      rpc_table = scalars["DDR LOCK/UNLOCK NODE"]
      rpc_table&.delete(lock_param)
      if lock_reply
        scalars["DDR LOCK/UNLOCK NODE"] ||= {}
        scalars["DDR LOCK/UNLOCK NODE"][lock_param] = lock_reply
      end

      result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

      refute result[:success], label
      assert_equal :legal_name_busy, result[:error], label
      assert_empty b_index_lister_calls, label
      assert_empty legl_calls, label
      assert_empty unlock_calls, label
      assert_equal 1, lock_calls.size, label
    end
  end

  def test_update_legal_names_blank_add_unlock_rpc_error_still_returns_success
    client = legal_name_unlock_error_client
    client.set_authenticated("501")
    seed_blank_add_prechecks_on(client, server_today: SERVER_TODAY_FM, max_ien: 41)
    seed_legl_success_on(client, "42")

    result = Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }, client: client
    )

    assert result[:success], result.inspect
    assert_equal 42, result[:ien]
  end

  def test_update_legal_names_blank_add_runs_lock_through_unlock_inside_synchronize_wire
    client, trace = legal_name_wire_trace_client
    client.set_authenticated("501")
    seed_blank_add_prechecks_on(client, server_today: SERVER_TODAY_FM, max_ien: 41)
    seed_legl_success_on(client, "42")

    Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }, client: client
    )

    refute_empty trace[:sync_opens], "update_legal_names must open synchronize_wire"
    assert_equal 1, trace[:sync_opens].size,
                 "lock through unlock must run under one outer synchronize_wire from update_legal_names"
    first_open = trace[:sync_opens].first
    lock_idx = trace[:call_records].index do |rec|
      rec[:rpc] == "DDR LOCK/UNLOCK NODE" && rec[:params].first["LOCKMODE"] == "1"
    end
    refute_nil lock_idx
    assert_operator first_open, :<, lock_idx, "wire lock must open before the B-node lock RPC"
    assert trace[:sync_opens].all? { |open_idx| open_idx < lock_idx },
           "lock through unlock must not run in a second outer synchronize_wire"

    tracked = trace[:call_records].select do |rec|
      case rec[:rpc]
      when "DDR LOCK/UNLOCK NODE"
        true
      when "DDR LISTER"
        true
      when "AGG UPDATE LEGAL NAMES"
        true
      when "DDR GETS ENTRY DATA"
        rec[:params].first["FIELDS"].to_s.include?(".01")
      else
        false
      end
    end
    refute_empty tracked
    assert tracked.all? { |rec| rec[:inside_wire] },
           "lock, B read, max-IEN read, LEGL, post-check, and unlock must run inside synchronize_wire"
  end

  # M3: transport errors (ConnectionError / TimeoutError, not RpcError) on a
  # completed write must not escape as a bare exception.
  def test_update_legal_names_blank_add_post_read_transport_error_is_unverified_written
    [ RpmsRpc::Client::ConnectionError, RpmsRpc::Client::TimeoutError ].each do |klass|
      client = legal_name_post_check_error_client(klass)
      client.set_authenticated("501")
      seed_blank_add_prechecks_on(client, server_today: SERVER_TODAY_FM, max_ien: 41)
      seed_legl_success_on(client, "42")

      result = Agg.update_legal_names(
        dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }, client: client
      )

      refute result[:success], klass.name
      assert_equal :legal_name_unverified, result[:error], klass.name
      assert_equal true, result[:written], klass.name
      assert_equal 42, result[:ien], klass.name
      unlocks = client.received_calls.select do |c|
        c[:rpc] == "DDR LOCK/UNLOCK NODE" && !c[:params].first.key?("LOCKMODE")
      end
      assert_equal 1, unlocks.size, klass.name
    end
  end

  def test_update_legal_names_blank_add_unlock_transport_error_does_not_mask_success
    [ RpmsRpc::Client::ConnectionError, RpmsRpc::Client::TimeoutError ].each do |klass|
      client = legal_name_unlock_error_client(klass)
      client.set_authenticated("501")
      seed_blank_add_prechecks_on(client, server_today: SERVER_TODAY_FM, max_ien: 41)
      seed_legl_success_on(client, "42")

      result = Agg.update_legal_names(
        dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }, client: client
      )

      assert result[:success], "#{klass.name}: #{result.inspect}"
      assert_equal 42, result[:ien], klass.name
    end
  end

  def test_update_legal_names_blank_add_unlock_transport_error_does_not_mask_original_exception
    error_client = legal_name_unlock_error_client(RpmsRpc::Client::ConnectionError, also_lister_rpc_error: true)
    error_client.set_authenticated("501")
    seed_blank_add_prechecks_on(error_client, server_today: SERVER_TODAY_FM, max_ien: 41)

    err = assert_raises(RpmsRpc::Client::RpcError) do
      Agg.update_legal_names(
        dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }, client: error_client
      )
    end
    assert_match(/broker failure/, err.message)
    refute error_client.received_calls.any? { |c| c[:rpc] == "AGG UPDATE LEGAL NAMES" }
  end

  # LOW: a non-numeric RIEN is a malformed reply, not a takeover of IEN 0.
  def test_update_legal_names_blank_add_non_numeric_rien_is_not_reported_as_takeover
    [ "abc", "42x", "4.2", "-3", " " ].each do |bad|
      @mock.received_calls.clear
      seed_blank_add_prechecks(server_today: SERVER_TODAY_FM, max_ien: 41)
      wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}1^^#{bad}#{RS}#{US}"
      seed_global("AGG UPDATE LEGAL NAMES", DFN, wire)

      result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

      refute result[:success], bad.inspect
      refute_equal :legal_name_takeover, result[:error], bad.inspect
      assert_equal :legal_name_unverified, result[:error], bad.inspect
      assert_equal true, result[:written], bad.inspect
      refute_equal 0, result[:ien], bad.inspect
      assert_empty ddr_calls, "#{bad.inspect}: no post-read of a guessed IEN"
    end
  end

  private

  # Serves B-index lister replies from a queue (String text, or an exception
  # to raise); the max-IEN lister and everything else fall through to seeds.
  def b_reread_client(queue)
    klass = Class.new(RpmsRpc::MockClient) do
      attr_reader :b_reads, :b_read_positions

      define_method(:initialize) do
        super()
        @queue = queue.dup
        @b_reads = 0
        @b_read_positions = []
      end

      define_method(:call_rpc) do |rpc_name, *params|
        if rpc_name == "DDR LISTER" && params.first.is_a?(Hash) && params.first["XREF"] == "B"
          @b_reads += 1
          @b_read_positions << received_calls.size
          reply = @queue.shift
          raise reply if reply.is_a?(Exception)

          super(rpc_name, *params) # records the call
          return reply
        end

        super(rpc_name, *params)
      end
    end
    client = klass.new
    client.set_authenticated("501")
    client
  end

  def seed_legl_rejection_prechecks_on(client, wire)
    seed_blank_add_server_today_flow(SERVER_TODAY_FM, mock: client)
    seed_legal_name_lock_on(client, SERVER_TODAY_FM)
    seed_legal_name_unlock_on(client, SERVER_TODAY_FM)
    client.seed(:ddr_lister, max_ien_lister_param.to_s, "[Data]\n41")
    tables = client.instance_variable_get(:@lines) || {}
    tables["AGG UPDATE LEGAL NAMES"] ||= {}
    tables["AGG UPDATE LEGAL NAMES"][DFN] = wire
    client.instance_variable_set(:@lines, tables)
  end

  def seed_gets(file, iens, fields, text, flags: "I")
    key = Ddr.gets_entry_param(file: file, iens: iens, fields: fields, flags: flags).to_s
    @mock.seed(:ddr_gets_entry_data, key, text)
  end

  def seed_name_patient(rien, patient_dfn)
    seed_gets("9000033", "#{rien},", ".02", "[Data]\n9000033^#{rien},^.02^#{patient_dfn}^#{patient_dfn}")
  end

  def seed_legal_name_post_check(rien, patient_dfn, day_fm: SERVER_TODAY_FM, mock: @mock)
    text = "[Data]\n9000033^#{rien},^.01^#{day_fm}^\n9000033^#{rien},^.02^#{patient_dfn}^#{patient_dfn}"
    key = Ddr.gets_entry_param(file: "9000033", iens: "#{rien},", fields: ".01;.02", flags: "I").to_s
    mock.seed(:ddr_gets_entry_data, key, text)
  end

  def seed_legl_success(rien, dfn: DFN, day_fm: SERVER_TODAY_FM, post_check: true)
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}1^^#{rien}#{RS}#{US}"
    seed_global("AGG UPDATE LEGAL NAMES", dfn, wire)
    seed_legal_name_post_check(rien, dfn, day_fm: day_fm) if post_check
  end

  def seed_legl_success_on(client, rien, dfn: DFN, day_fm: SERVER_TODAY_FM, post_check: true)
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}1^^#{rien}#{RS}#{US}"
    tables = client.instance_variable_get(:@lines) || {}
    tables["AGG UPDATE LEGAL NAMES"] ||= {}
    tables["AGG UPDATE LEGAL NAMES"][dfn.to_s] = wire
    client.instance_variable_set(:@lines, tables)
    seed_legal_name_post_check(rien, dfn, day_fm: day_fm, mock: client) if post_check
  end

  def seed_blank_add_prechecks_on(client, server_today:, max_ien:, b_text: "[Data]\n")
    seed_blank_add_server_today_flow(server_today, mock: client)
    seed_legal_name_lock_on(client, server_today)
    seed_legal_name_unlock_on(client, server_today)
    seed_b_lister_on(client, day: fileman_prior_calendar_day(server_today), text: "[Data]\n")
    seed_b_lister_on(client, day: server_today, text: b_text)
    max_text = max_ien.zero? ? "[Data]\n" : "[Data]\n#{max_ien}"
    client.seed(:ddr_lister, max_ien_lister_param.to_s, max_text)
  end

  def legal_name_post_check_error_client(error_class = RpmsRpc::Client::RpcError)
    Class.new(RpmsRpc::MockClient) do
      define_method(:call_rpc) do |rpc_name, *params|
        if rpc_name == "DDR GETS ENTRY DATA" &&
           params.first.is_a?(Hash) &&
           params.first["FIELDS"].to_s.include?(".01")
          raise error_class, "DDR GETS ENTRY DATA: broker failure"
        end

        super(rpc_name, *params)
      end
    end.new
  end

  def legal_name_unlock_error_client(error_class = RpmsRpc::Client::RpcError, also_lister_rpc_error: false)
    Class.new(RpmsRpc::MockClient) do
      define_method(:call_rpc) do |rpc_name, *params|
        param = params.first
        if rpc_name == "DDR LOCK/UNLOCK NODE" && param.is_a?(Hash) && !param.key?("LOCKMODE")
          raise error_class, "DDR LOCK/UNLOCK NODE: unlock failure"
        end
        if also_lister_rpc_error && rpc_name == "DDR LISTER" && param.is_a?(Hash) && param["XREF"] == "#"
          raise RpmsRpc::Client::RpcError, "DDR LISTER: broker failure"
        end

        super(rpc_name, *params)
      end
    end.new
  end

  def legal_name_wire_trace_client
    trace = { depth: 0, sync_opens: [], call_records: [] }
    client = Class.new(RpmsRpc::MockClient) do
      define_method(:initialize) do
        super()
        @legal_name_wire_trace = trace
      end

      define_method(:synchronize_wire) do |&block|
        if @legal_name_wire_trace[:depth].zero?
          @legal_name_wire_trace[:sync_opens] << @legal_name_wire_trace[:call_records].length
        end
        @legal_name_wire_trace[:depth] += 1
        begin
          super(&block)
        ensure
          @legal_name_wire_trace[:depth] -= 1
        end
      end

      define_method(:call_rpc) do |rpc_name, *params|
        @legal_name_wire_trace[:call_records] << {
          rpc: rpc_name,
          params: params,
          inside_wire: @legal_name_wire_trace[:depth].positive?
        }
        super(rpc_name, *params)
      end
    end.new
    [ client, trace ]
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

  def encode_fileman(date)
    (date.year - 1700) * 10_000 + date.month * 100 + date.day
  end

  def decode_fileman(fm)
    Date.new(fm / 10_000 + 1700, (fm / 100) % 100, fm % 100)
  end

  def fileman_yesterday(fm)
    fileman_prior_calendar_day(fm)
  end

  def fileman_prior_calendar_day(fm)
    encode_fileman(decode_fileman(fm) - 1)
  end

  def mmddyyyy_from_fileman(fm)
    d = decode_fileman(fm)
    format("%02d/%02d/%04d", d.month, d.day, d.year)
  end

  def legal_name_b_lock_node(day)
    "^AUPNNAMC(\"B\",#{day})"
  end

  def legal_name_b_lock_param(day)
    Ddr.lock_param(node: legal_name_b_lock_node(day), timeout: 5)
  end

  def legal_name_b_unlock_param(day)
    Ddr.unlock_param(node: legal_name_b_lock_node(day))
  end

  def seed_legal_name_lock(day, acquired: true, mock: @mock)
    mock.seed_scalar(:ddr_lock_unlock_node, legal_name_b_lock_param(day).to_s, acquired)
  end

  def seed_legal_name_unlock(day, success: true, mock: @mock)
    mock.seed_scalar(:ddr_lock_unlock_node, legal_name_b_unlock_param(day).to_s, success)
  end

  def seed_legal_name_lock_on(client, day, acquired: true)
    seed_legal_name_lock(day, acquired: acquired, mock: client)
  end

  def seed_legal_name_unlock_on(client, day, success: true)
    seed_legal_name_unlock(day, success: success, mock: client)
  end

  def seed_blank_add_server_today_flow(server_today, mock: @mock)
    mock.seed_scalar(:orwu_dt, "T", server_today.to_s)
    mmdd = mmddyyyy_from_fileman(server_today)
    mock.seed_scalar(:orwu_dt, mmdd, server_today.to_s)
  end

  def seed_blank_add_server_today_flow_on(client, server_today)
    seed_blank_add_server_today_flow(server_today, mock: client)
  end

  def seed_b_lister_on(client, day:, text:)
    seed_b_lister_with_mock(client, day: day, text: text)
  end

  def b_lister_param(day, from: nil)
    Ddr.lister_param(
      file: "9000033",
      fields: "@;.01I",
      flags: "IPQ",
      max: "1",
      xref: "B",
      from: from || "#{day - 1}.9999999"
    )
  end

  def seed_b_lister(day:, text:, from: nil)
    seed_b_lister_with_mock(@mock, day: day, text: text, from: from)
  end

  def max_ien_lister_param
    Ddr.lister_param(file: "9000033", fields: "@", flags: "IPB", max: "1", xref: "#")
  end

  def seed_b_lister_with_mock(mock, day:, text:, from: nil)
    mock.seed(:ddr_lister, b_lister_param(day, from: from).to_s, text)
  end

  def seed_max_ien_lister(text)
    @mock.seed(:ddr_lister, max_ien_lister_param.to_s, text)
  end

  def seed_blank_add_b_and_max_listers(server_today:, b_text: "[Data]\n")
    seed_b_lister(day: fileman_prior_calendar_day(server_today), text: "[Data]\n")
    seed_b_lister(day: server_today, text: b_text)
    seed_max_ien_lister("[Data]\n0")
  end

  def seed_blank_add_prechecks(server_today:, max_ien:, b_text: "[Data]\n")
    seed_blank_add_server_today_flow(server_today)
    seed_legal_name_lock(server_today)
    seed_legal_name_unlock(server_today)
    seed_b_lister(day: fileman_prior_calendar_day(server_today), text: "[Data]\n")
    seed_b_lister(day: server_today, text: b_text)
    max_text = max_ien.zero? ? "[Data]\n" : "[Data]\n#{max_ien}"
    seed_max_ien_lister(max_text)
  end

  def b_index_lister_days_from_calls
    b_index_lister_calls.map { |c| b_lister_day_from_call(c) }
  end

  def b_lister_day_from_call(call)
    call[:params].first["FROM"].split(".").first.to_i + 1
  end

  def orwu_dt_calls
    @mock.received_calls.select { |c| c[:rpc] == "ORWU DT" }
  end

  def lister_calls
    @mock.received_calls.select { |c| c[:rpc] == "DDR LISTER" }
  end

  def b_index_lister_calls
    lister_calls.select { |c| c[:params].first["XREF"] == "B" }
  end

  def max_ien_lister_calls
    lister_calls.select { |c| c[:params].first["XREF"] == "#" }
  end

  def ddr_lock_unlock_calls
    @mock.received_calls.select { |c| c[:rpc] == "DDR LOCK/UNLOCK NODE" }
  end

  def lock_calls
    ddr_lock_unlock_calls.select { |c| c[:params].first["LOCKMODE"] == "1" }
  end

  def unlock_calls
    ddr_lock_unlock_calls.select { |c| !c[:params].first.key?("LOCKMODE") }
  end
end
