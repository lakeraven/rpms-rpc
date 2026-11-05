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
    seed_name_patient("42", DFN)
    seed_legl_success("42")

    result = Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }
    )

    assert result[:success], result.inspect
    assert_equal 42, result[:ien]
    assert_equal 1, orwu_dt_calls.size
    assert_equal [ "T", "" ], orwu_dt_calls.first[:params]
    assert_equal "CIAV VUECENTRIC", orwu_dt_calls.first[:context]
    assert_equal 2, b_index_lister_calls.size, "today and yesterday B reads"
    assert_equal 1, max_ien_lister_calls.size
    call = @mock.received_calls.find { |c| c[:rpc] == "AGG UPDATE LEGAL NAMES" }
    assert_equal Agg::CONTEXT, call[:context]
    assert_equal DFN, call[:params][0]
    assert_equal "A", call[:params][1]
    assert_equal 1, ddr_calls.size, "post-check .02 read only"
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

  # --- update_legal_names guard specs (rpms-rpc#420): failing until lib adds pre/post checks ---

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
    end
  end

  def test_update_legal_names_blank_add_refuses_when_b_index_row_occupies_server_today
    @mock.seed_scalar(:orwu_dt, "T", SERVER_TODAY_FM.to_s)
    seed_b_lister(day: fileman_yesterday(SERVER_TODAY_FM), text: "[Data]\n")
    seed_b_lister(day: SERVER_TODAY_FM, text: "[Data]\n55^#{SERVER_TODAY_FM}")

    result = Agg.update_legal_names(
      dfn: DFN_B.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }
    )

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_date_taken, result[:error]
    assert_match(/3261105/, result[:message].to_s)
    assert_empty legl_calls
  end

  def test_update_legal_names_blank_add_refuses_when_b_index_row_has_time_on_server_today
    @mock.seed_scalar(:orwu_dt, "T", SERVER_TODAY_FM.to_s)
    seed_b_lister(day: fileman_yesterday(SERVER_TODAY_FM), text: "[Data]\n")
    seed_b_lister(day: SERVER_TODAY_FM, text: "[Data]\n55^#{SERVER_TODAY_FM}.143")

    result = Agg.update_legal_names(
      dfn: DFN_B.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }
    )

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_date_taken, result[:error]
    assert_empty legl_calls
  end

  def test_update_legal_names_blank_add_refuses_when_b_index_row_occupies_yesterday
    @mock.seed_scalar(:orwu_dt, "T", SERVER_TODAY_FM.to_s)
    yesterday = fileman_yesterday(SERVER_TODAY_FM)
    seed_b_lister(day: yesterday, text: "[Data]\n55^#{yesterday}")
    seed_b_lister(day: SERVER_TODAY_FM, text: "[Data]\n")

    result = Agg.update_legal_names(
      dfn: DFN_B.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }
    )

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_date_taken, result[:error]
    assert_match(/#{yesterday}/, result[:message].to_s)
    assert_empty legl_calls
  end

  def test_update_legal_names_blank_add_refuses_agglndtc_with_colon_without_legl
    @mock.seed_scalar(:orwu_dt, "T", SERVER_TODAY_FM.to_s)
    seed_blank_add_b_and_max_listers(server_today: SERVER_TODAY_FM)

    result = Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "",
      params: { "AGGLNMC" => "SYNTH", "AGGLNDTC" => "3261105:143000" }
    )

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert_empty legl_calls
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
    seed_name_patient("55", DFN)
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}1^^55#{RS}#{US}"
    seed_global("AGG UPDATE LEGAL NAMES", DFN_B, wire)

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
    @mock.seed_scalar(:orwu_dt, "T", SERVER_TODAY_FM.to_s)
    seed_b_lister(day: fileman_yesterday(SERVER_TODAY_FM), text: "[Data]\n")
    seed_b_lister(day: SERVER_TODAY_FM, text: "SYNTHETIC BROKER NOISE")
    seed_max_ien_lister("[Data]\n60")

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert_empty legl_calls
  end

  def test_update_legal_names_blank_add_agglndtc_orwu_converts_then_checks_three_b_days
    @mock.seed_scalar(:orwu_dt, "T", SERVER_TODAY_FM.to_s)
    @mock.seed_scalar(:orwu_dt, "11/01/2026", "3261101")
    seed_b_lister(day: 3_261_101, text: "[Data]\n70^3261101")
    seed_b_lister(day: 3_261_104, text: "[Data]\n")
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
    assert_equal 2, orwu_dt_calls.size
    assert_equal [ "T", "" ], orwu_dt_calls[0][:params]
    assert_equal [ "11/01/2026", "TS" ], orwu_dt_calls[1][:params]
    assert(orwu_dt_calls.all? { |c| c[:context] == "CIAV VUECENTRIC" })
    assert_equal [ 3_261_101, 3_261_104, SERVER_TODAY_FM ], b_index_lister_days_from_calls
  end

  def test_update_legal_names_blank_add_agglndtc_orwu_minus_one_falls_back_to_today_yesterday
    @mock.seed_scalar(:orwu_dt, "T", SERVER_TODAY_FM.to_s)
    @mock.seed_scalar(:orwu_dt, "SYNTH/BAD-DATE", "-1")
    seed_blank_add_prechecks(server_today: SERVER_TODAY_FM, max_ien: 41)
    seed_name_patient("42", DFN)
    seed_legl_success("42")

    result = Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "",
      params: { "AGGLNMC" => "SYNTH", "AGGLNDTC" => "SYNTH/BAD-DATE" }
    )

    assert result[:success], result.inspect
    assert_equal 42, result[:ien]
    assert_equal 2, orwu_dt_calls.size
    assert_equal [ "SYNTH/BAD-DATE", "TS" ], orwu_dt_calls.last[:params]
    assert_equal 2, b_index_lister_calls.size, "fallback uses server today and yesterday only"
    assert_equal 1, ddr_calls.size
  end

  def test_update_legal_names_blank_add_agglndtc_orwu_non_fileman_reply_unverified
    @mock.seed_scalar(:orwu_dt, "T", SERVER_TODAY_FM.to_s)
    @mock.seed_scalar(:orwu_dt, "11/01/2026", "abc")

    result = Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "",
      params: { "AGGLNMC" => "SYNTH", "AGGLNDTC" => "11/01/2026" }
    )

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert_empty legl_calls
  end

  def test_update_legal_names_blank_add_b_reads_use_prior_day_from_at_month_boundary
    server_today = 3_270_101
    @mock.seed_scalar(:orwu_dt, "T", server_today.to_s)
    seed_b_lister(day: 3_261_231, text: "[Data]\n")
    seed_b_lister(day: server_today, text: "[Data]\n")
    seed_max_ien_lister("[Data]\n41")

    Agg.update_legal_names(
      dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" }
    )

    assert_equal 2, b_index_lister_calls.size
    froms = b_index_lister_calls.map { |c| c[:params].first["FROM"] }
    assert_equal [ b_lister_param(3_261_231)["FROM"], b_lister_param(server_today)["FROM"] ], froms
    assert_equal "3261230.9999999", froms.first
    assert_equal "3270100.9999999", froms.last
  end

  def test_update_legal_names_blank_add_allows_b_lister_first_row_on_later_day
    seed_blank_add_prechecks(server_today: SERVER_TODAY_FM, max_ien: 41)
    seed_b_lister(day: SERVER_TODAY_FM, text: "[Data]\n80^3261106")
    seed_name_patient("42", DFN)
    seed_legl_success("42")

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    assert result[:success], result.inspect
    assert_equal 42, result[:ien]
    assert_equal 1, legl_calls.size
  end

  def test_update_legal_names_blank_add_empty_max_ien_file_allows_first_rien
    @mock.seed_scalar(:orwu_dt, "T", SERVER_TODAY_FM.to_s)
    seed_b_lister(day: fileman_yesterday(SERVER_TODAY_FM), text: "[Data]\n")
    seed_b_lister(day: SERVER_TODAY_FM, text: "[Data]\n")
    seed_max_ien_lister("[Data]\n")
    seed_name_patient("1", DFN)
    wire = "5\x00I00010RESULT^T01024ERROR^I00010RIEN#{RS}1^^1#{RS}#{US}"
    seed_global("AGG UPDATE LEGAL NAMES", DFN, wire)

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    assert result[:success], result.inspect
    assert_equal 1, result[:ien]
  end

  def test_update_legal_names_blank_add_unverified_when_max_ien_lister_first_ien_non_numeric
    @mock.seed_scalar(:orwu_dt, "T", SERVER_TODAY_FM.to_s)
    seed_b_lister(day: fileman_yesterday(SERVER_TODAY_FM), text: "[Data]\n")
    seed_b_lister(day: SERVER_TODAY_FM, text: "[Data]\n")
    seed_max_ien_lister("[Data]\nX^")

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "A", rien: "", params: { "AGGLNMC" => "SYNTH" })

    refute_nil result
    refute result[:success]
    assert_equal :legal_name_unverified, result[:error]
    assert_empty legl_calls
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

  def encode_fileman(date)
    (date.year - 1700) * 10_000 + date.month * 100 + date.day
  end

  def decode_fileman(fm)
    Date.new(fm / 10_000 + 1700, (fm / 100) % 100, fm % 100)
  end

  def fileman_yesterday(fm)
    encode_fileman(decode_fileman(fm) - 1)
  end

  def b_lister_param(day)
    Ddr.lister_param(
      file: "9000033",
      fields: "@;.01I",
      flags: "IPQ",
      max: "1",
      xref: "B",
      from: "#{day.to_i - 1}.9999999"
    )
  end

  def max_ien_lister_param
    Ddr.lister_param(file: "9000033", fields: "@", flags: "IPB", max: "1", xref: "#")
  end

  def seed_b_lister(day:, text:)
    @mock.seed(:ddr_lister, b_lister_param(day).to_s, text)
  end

  def seed_max_ien_lister(text)
    @mock.seed(:ddr_lister, max_ien_lister_param.to_s, text)
  end

  def seed_blank_add_b_and_max_listers(server_today:)
    seed_b_lister(day: fileman_yesterday(server_today), text: "[Data]\n")
    seed_b_lister(day: server_today, text: "[Data]\n")
    seed_max_ien_lister("[Data]\n0")
  end

  def seed_blank_add_prechecks(server_today:, max_ien:)
    @mock.seed_scalar(:orwu_dt, "T", server_today.to_s)
    seed_blank_add_b_and_max_listers(server_today: server_today)
    seed_max_ien_lister("[Data]\n#{max_ien}")
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
end
