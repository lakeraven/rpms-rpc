# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/client"
require "rpms_rpc/mock_client"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/ddr_fileman"

# Agg.update_legal_names: LEGL^AGGPTNAM (AGG UPDATE LEGAL NAMES), EDIT and
# DELETE of an existing #9000033 row only (rpms-rpc#627). A blank-RIEN add is
# refused in this slice. Synthetic data only.
class AggLegalNamesTest < Minitest::Test
  Agg = RpmsRpc::Agg
  RS = "\x1e"
  US = "\x1f"
  DFN = "990031"
  DFN_B = "990032"
  RIEN = "42"
  LEGL = "AGG UPDATE LEGAL NAMES"
  GETS = "DDR GETS ENTRY DATA"
  DDR_CONTEXT = "CIAV VUECENTRIC"
  HEADER = "I00010RESULT^T01024ERROR^I00010RIEN"
  EDIT = { "AGGLNMC" => "SYNTH,LEGAL" }.freeze

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # -- 1-4: refusals before any RPC ------------------------------------------

  def test_refuses_non_canonical_dfn_without_rpc
    [ "0990031", " 990031", "990031 ", "abc", "", nil, 0, -5 ].each do |bad|
      assert_refused :invalid_dfn, "dfn #{bad.inspect}", dfn: bad, proc: "D", rien: RIEN, params: {}
    end
  end

  def test_refuses_proc_other_than_a_d_or_empty_without_rpc
    [ "d", "a", "X", " D", "DELETE", nil ].each do |bad|
      assert_refused :invalid_proc, "proc #{bad.inspect}", dfn: DFN, proc: bad, rien: RIEN, params: {}
    end
  end

  def test_refuses_blank_rien_for_every_proc_and_says_add_is_unsupported
    [ "A", "D", "" ].each do |proc|
      [ "", nil, "  " ].each do |blank|
        result = assert_refused :invalid_rien, "proc #{proc.inspect} rien #{blank.inspect}",
                                dfn: DFN, proc: proc, rien: blank, params: proc == "D" ? {} : EDIT
        assert_match(/add/i, result[:message]) if proc == "A"
        assert_match(/not supported/i, result[:message]) if proc == "A"
      end
    end
  end

  def test_refuses_non_canonical_rien_without_rpc
    [ "0", "042", "4 2", "-1", "abc", "1.5" ].each do |bad|
      assert_refused :invalid_rien, "rien #{bad.inspect}", dfn: DFN, proc: "D", rien: bad, params: {}
    end
  end

  def test_legal_name_parms_allowlist_excludes_rien_and_dfn
    assert_equal %w[AGGLNDTC AGGLNMC AGGLNPRF AGGLGDOC AGGLNEBY ALIASCK], Agg::LEGAL_NAME_PARMS
  end

  def test_refuses_params_that_are_not_a_hash_or_name_an_unlisted_parameter
    [ nil, "AGGLNMC=X", [ [ "AGGLNMC", "X" ] ] ].each do |bad|
      assert_refused :invalid_param, "params #{bad.inspect}", dfn: DFN, proc: "", rien: RIEN, params: bad
    end
    [ "RIEN", "DFN", :RIEN, "rien", "AGGLNAME", "BMXSEC", "agglnmc" ].each do |name|
      assert_refused :invalid_param, "name #{name.inspect}", dfn: DFN, proc: "", rien: RIEN, params: { name => "7" }
    end
  end

  def test_refuses_duplicate_names_and_any_edit_without_exactly_one_entry
    [ { "AGGLNMC" => "X", AGGLNMC: "Y" }, {}, { "AGGLNMC" => "X", "AGGLNPRF" => "Y" } ].each do |bad|
      [ "A", "" ].each do |proc|
        assert_refused :invalid_param, "proc #{proc.inspect} params #{bad.inspect}",
                       dfn: DFN, proc: proc, rien: RIEN, params: bad
      end
    end
  end

  def test_refuses_delete_with_params_and_blank_values
    assert_refused :invalid_param, "delete with params", dfn: DFN, proc: "D", rien: RIEN, params: EDIT
    [ "", "   ", nil ].each do |blank|
      assert_refused :invalid_param, "value #{blank.inspect}", dfn: DFN, proc: "", rien: RIEN, params: { "AGGLNMC" => blank }
    end
  end

  def test_refuses_agglndtc_that_is_not_an_absolute_real_calendar_day
    [ "T", "T-1", "TODAY", "11/5/2026", "2026-11-05", "02/30/2026", "13/01/2026", "11/05/2026@1200" ].each do |bad|
      assert_refused :invalid_param, "AGGLNDTC #{bad.inspect}", dfn: DFN, proc: "A", rien: RIEN, params: { "AGGLNDTC" => bad }
    end
  end

  def test_checks_run_in_order_dfn_proc_rien_params_and_leave_the_hash_alone
    assert_refused :invalid_dfn, "dfn first", dfn: "abc", proc: "X", rien: "0", params: nil
    assert_refused :invalid_proc, "proc second", dfn: DFN, proc: "X", rien: "0", params: nil
    assert_refused :invalid_rien, "rien third", dfn: DFN, proc: "D", rien: "0", params: nil

    seed_owner(RIEN, DFN)
    seed_legl("1^^#{RIEN}")
    given = { AGGLNMC: "SYNTH,LEGAL" }
    Agg.update_legal_names(dfn: DFN, proc: "", rien: RIEN, params: given)
    assert_equal({ AGGLNMC: "SYNTH,LEGAL" }, given)
    refute given.frozen?
  end

  def test_value_holding_the_parameter_delimiter_raises_before_any_rpc
    seed_owner(RIEN, DFN)
    assert_raises(ArgumentError) do
      Agg.update_legal_names(dfn: DFN, proc: "", rien: RIEN, params: { "AGGLNMC" => "SYNTH#{Agg::PARM_DELIM}DFN=1" })
    end
    assert_empty @mock.received_calls
  end

  # -- 5: ownership read ------------------------------------------------------

  def test_ownership_read_is_ddr_gets_of_field_02_under_ciav_before_legl
    seed_owner(RIEN, DFN)
    seed_legl("1^^#{RIEN}")

    Agg.update_legal_names(dfn: DFN.to_i, proc: "D", rien: RIEN.to_i, params: {})

    assert_equal [ GETS, LEGL ], @mock.received_calls.map { |c| c[:rpc] }
    read = @mock.received_calls.first
    assert_equal [ gets_param(RIEN) ], read[:params]
    assert_equal DDR_CONTEXT, read[:context]
  end

  def test_unverifiable_owner_is_rien_unverified_without_legl
    { "no reply" => nil, "error" => [ "[ERROR]" ], "malformed" => [ "garbage" ],
      "blank .02" => [ "[Data]", "9000033^#{RIEN},^.02^^" ], "no .02 row" => [ "[Data]" ] }.each do |label, lines|
      seed_lines(GETS, gets_param(RIEN).to_s, lines)
      [ [ "D", {} ], [ "", EDIT ] ].each do |proc, params|
        assert_read_refusal :rien_unverified, "#{label} proc #{proc.inspect}", proc: proc, params: params
      end
    end
  end

  def test_row_of_another_patient_is_rien_not_for_dfn_without_legl
    seed_owner(RIEN, DFN_B)
    [ [ "D", {} ], [ "A", EDIT ], [ "", EDIT ] ].each do |proc, params|
      assert_read_refusal :rien_not_for_dfn, "proc #{proc.inspect}", proc: proc, params: params
    end
  end

  def test_rpc_error_from_the_ownership_read_propagates_without_legl
    client = Class.new(RpmsRpc::MockClient) do
      def seeded_reply(rpc_name, *params)
        super.tap { raise RpmsRpc::Client::RpcError, "broker failure" if rpc_name == "DDR GETS ENTRY DATA" }
      end
    end.new

    assert_raises(RpmsRpc::Client::RpcError) do
      Agg.update_legal_names(dfn: DFN, proc: "D", rien: RIEN, params: {}, client: client)
    end
    assert_equal [ GETS ], client.received_calls.map { |c| c[:rpc] }
  end

  # -- 6: LEGL wire and reply -------------------------------------------------

  def test_delete_sends_empty_parms_and_returns_the_rien
    seed_owner(RIEN, DFN)
    seed_legl("1^^#{RIEN}")

    result = Agg.update_legal_names(dfn: DFN.to_i, proc: "D", rien: RIEN, params: {})

    assert_equal({ success: true, ien: 42 }, result)
    assert_equal [ DFN, "D", RIEN, "" ], legl_call[:params]
    assert_equal Agg::CONTEXT, legl_call[:context]
  end

  def test_edit_sends_one_name_value_entry_for_proc_empty_and_proc_a
    seed_owner(RIEN, DFN)
    seed_legl("1^^#{RIEN}")
    { [ "", { AGGLNMC: "SYNTH,LEGAL" } ] => "AGGLNMC=SYNTH,LEGAL",
      [ "A", { "AGGLNDTC" => "11/05/2026" } ] => "AGGLNDTC=11/05/2026" }.each do |(proc, params), parms|
      @mock.received_calls.clear
      result = Agg.update_legal_names(dfn: DFN, proc: proc, rien: RIEN.to_i, params: params)

      assert_equal({ success: true, ien: 42 }, result, "proc #{proc.inspect}")
      assert_equal [ DFN, proc, RIEN, parms ], legl_call[:params]
      assert_equal Agg::CONTEXT, legl_call[:context]
    end
  end

  def test_legl_rejection_row_is_agg_rejected_with_its_text
    seed_owner(RIEN, DFN)
    seed_legl("-1^AGGLNMC not a valid parameter for this update^^")

    result = Agg.update_legal_names(dfn: DFN, proc: "", rien: RIEN, params: EDIT)

    assert_equal({ success: false, error: :agg_rejected, message: "AGGLNMC not a valid parameter for this update" }, result)
  end

  def test_no_legl_reply_is_nil
    seed_owner(RIEN, DFN)

    assert_nil Agg.update_legal_names(dfn: DFN, proc: "D", rien: RIEN, params: {})
    assert_equal 1, @mock.received_calls.count { |c| c[:rpc] == LEGL }
  end

  def test_success_row_for_another_or_blank_rien_is_unverified_and_written
    seed_owner(RIEN, DFN)
    [ "1^^43", "1^^", "1^^042" ].each do |row|
      seed_legl(row)
      result = Agg.update_legal_names(dfn: DFN, proc: "", rien: RIEN, params: EDIT)

      assert_equal false, result[:success], row
      assert_equal :legal_name_unverified, result[:error], row
      assert_equal true, result[:written], row
      assert_kind_of String, result[:message]
      refute result.key?(:ien), row
    end
  end

  # -- 7-10 --------------------------------------------------------------------

  def test_read_and_legl_run_inside_one_synchronize_wire_block
    client = Class.new(RpmsRpc::MockClient) do
      attr_reader :wire_entries, :inside

      def synchronize_wire(&block)
        @wire_entries = wire_entries.to_i + 1 if @depth.to_i.zero?
        @depth = @depth.to_i + 1
        super(&block)
      ensure
        @depth -= 1
      end

      def seeded_reply(rpc_name, *params)
        (@inside ||= []) << [ rpc_name, @depth.to_i.positive? ]
        super
      end
    end.new
    seed_owner(RIEN, DFN, mock: client)
    seed_legl("1^^#{RIEN}", mock: client)

    result = Agg.update_legal_names(dfn: DFN, proc: "D", rien: RIEN, params: {}, client: client)

    assert_equal({ success: true, ien: 42 }, result)
    assert_equal [ [ GETS, true ], [ LEGL, true ] ], client.inside
    assert_equal 1, client.wire_entries, "one outer synchronize_wire block holds the read and the write"
  end

  def test_update_legal_names_is_non_idempotent_write_in_retry_safety
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(Agg, :update_legal_names)
  end

  def test_data_mapper_maps_agg_update_legal_names
    assert_equal LEGL, RpmsRpc::DataMapper[:agg_update_legal_names].rpc_name
  end

  private

  def gets_param(rien)
    RpmsRpc::DdrFileman.gets_entry_param(file: "9000033", iens: "#{rien},", fields: ".02", flags: "I")
  end

  def seed_lines(rpc, key, reply, mock: @mock)
    tables = mock.instance_variable_get(:@lines) || {}
    tables[rpc] ||= {}
    reply.nil? ? tables[rpc].delete(key.to_s) : tables[rpc][key.to_s] = reply
    mock.instance_variable_set(:@lines, tables)
  end

  def seed_owner(rien, owner, mock: @mock)
    seed_lines(GETS, gets_param(rien).to_s, [ "[Data]", "9000033^#{rien},^.02^#{owner}^" ], mock: mock)
  end

  def seed_legl(row, mock: @mock)
    seed_lines(LEGL, DFN, "5\x00#{HEADER}#{RS}#{row}#{RS}#{US}", mock: mock)
  end

  def legl_call
    calls = @mock.received_calls.select { |c| c[:rpc] == LEGL }
    assert_equal 1, calls.size, "exactly one #{LEGL} call"
    calls.first
  end

  # A refusal that sends nothing at all.
  def assert_refused(error, label, **args)
    @mock.received_calls.clear
    result = Agg.update_legal_names(**args)
    assert_equal false, result[:success], label
    assert_equal error, result[:error], label
    assert_kind_of String, result[:message], label
    assert_empty @mock.received_calls, "#{label}: no RPC may be sent"
    result
  end

  # A refusal decided by the ownership read: the read ran, LEGL did not.
  def assert_read_refusal(error, label, proc:, params:)
    @mock.received_calls.clear
    result = Agg.update_legal_names(dfn: DFN, proc: proc, rien: RIEN, params: params)
    assert_equal false, result[:success], label
    assert_equal error, result[:error], label
    assert_kind_of String, result[:message], label
    assert_equal [ GETS ], @mock.received_calls.map { |c| c[:rpc] }, label
  end
end
