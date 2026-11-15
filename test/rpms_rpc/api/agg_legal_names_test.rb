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
  MAPPINGS = { GETS => :ddr_gets_entry_data, LEGL => :agg_update_legal_names }.freeze

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

  # AGGLNEBY's EXEC files DUZ whatever the value, and ALIASCK has no field:
  # both answer success while filing nothing the caller asked.
  def test_legal_name_parms_allowlist_is_the_four_fields_legl_files
    assert_equal %w[AGGLNDTC AGGLNMC AGGLNPRF AGGLGDOC], Agg::LEGAL_NAME_PARMS
  end

  def test_refuses_agglneby_aliasck_and_keys_that_are_not_a_string_or_symbol
    seed_happy
    [ "AGGLNEBY", :AGGLNEBY, "ALIASCK", :ALIASCK, 7, to_s_object("AGGLNMC"), flipping("AGGLNMC", "RIEN") ].each do |name|
      assert_refused :invalid_param, "name #{name.inspect}", dfn: DFN, proc: "", rien: RIEN, params: { name => "SYNTH,LEGAL" }
    end
  end

  def test_refuses_values_that_are_not_a_string_or_for_agglnprf_a_positive_integer
    seed_happy
    [ [ "SYNTH,LEGAL" ], { "SYNTH" => "LEGAL" }, :SYNTH_LEGAL, 1.5, 12_345, to_s_object("SYNTH,LEGAL") ].each do |bad|
      assert_refused :invalid_param, "AGGLNMC #{bad.class}", dfn: DFN, proc: "", rien: RIEN, params: { "AGGLNMC" => bad }
    end
    [ 0, -1, 1.5, "07", "0", "1.5", "SYNTH", :"7", [ 7 ] ].each do |bad|
      assert_refused :invalid_param, "AGGLNPRF #{bad.inspect}", dfn: DFN, proc: "", rien: RIEN, params: { "AGGLNPRF" => bad }
    end
  end

  # FILE^DIE files "@" as a field delete (DIEF.m:61), refuses "^" (error 714),
  # and LEGL files with no validation, so the wrapper checks every value.
  def test_refuses_at_sign_control_characters_caret_and_surrounding_whitespace
    seed_happy
    [ "@", " @ ", "SYNTH\nLEGAL", "SYNTH\tLEGAL", "SYNTH#{RS}LEGAL", "SYNTH#{US}LEGAL", "SYNTH\x7fLEGAL",
      "SYNTH#{Agg::PARM_DELIM}DFN=1", "SYNTH^LEGAL", " SYNTH,LEGAL", "SYNTH,LEGAL ", "SYNTH,LEGAL\n" ].each do |bad|
      %w[AGGLNMC AGGLGDOC].each do |name|
        assert_refused :invalid_param, "#{name} #{bad.inspect}", dfn: DFN, proc: "", rien: RIEN, params: { name => bad }
      end
    end
    [ "@", " 7", "7 ", "7\n", "7^8" ].each do |bad|
      assert_refused :invalid_param, "AGGLNPRF #{bad.inspect}", dfn: DFN, proc: "", rien: RIEN, params: { "AGGLNPRF" => bad }
    end
  end

  def test_refuses_agglnmc_outside_3_to_45_and_agglgdoc_outside_3_to_20_characters
    seed_happy
    { "AGGLNMC" => [ "AB", "A" * 46 ], "AGGLGDOC" => [ "AB", "A" * 21 ] }.each do |name, values|
      values.each do |bad|
        assert_refused :invalid_param, "#{name} of #{bad.size}", dfn: DFN, proc: "", rien: RIEN, params: { name => bad }
      end
    end
  end

  def test_sends_values_at_the_length_bounds_and_agglnprf_as_string_or_integer
    seed_happy
    { { "AGGLNMC" => "ABC" } => "AGGLNMC=ABC", { "AGGLNMC" => "A" * 45 } => "AGGLNMC=#{'A' * 45}",
      { "AGGLGDOC" => "ABC" } => "AGGLGDOC=ABC", { AGGLGDOC: "A" * 20 } => "AGGLGDOC=#{'A' * 20}",
      { "AGGLNPRF" => "7" } => "AGGLNPRF=7", { AGGLNPRF: 7 } => "AGGLNPRF=7",
      { "AGGLNDTC" => "01/01/1800" } => "AGGLNDTC=01/01/1800",
      { "AGGLNDTC" => "12/31/2699" } => "AGGLNDTC=12/31/2699" }.each do |params, parms|
      @mock.received_calls.clear
      assert_equal({ success: true, ien: 42 }, Agg.update_legal_names(dfn: DFN, proc: "", rien: RIEN, params: params), parms)
      assert_equal [ DFN, "", RIEN, parms ], legl_call[:params]
    end
  end

  # The bytes validated are the bytes sent: a String subclass whose bytes are
  # "@" and whose to_s answers a valid name once is refused, or sent as that
  # one validated answer; "AGGLNMC=@" (a field delete) never reaches the wire.
  def test_each_value_is_converted_once_so_the_wire_carries_what_was_validated
    seed_happy
    value = Class.new(String) do
      def to_s = (@asked = @asked.to_i + 1) == 1 ? "SYNTH,LEGAL" : "@"
    end.new("@")

    result = Agg.update_legal_names(dfn: DFN, proc: "", rien: RIEN, params: { "AGGLNMC" => value })

    sent = @mock.received_calls.select { |c| c[:rpc] == LEGL }.map { |c| c[:params][3] }
    assert_includes [ [], [ "AGGLNMC=SYNTH,LEGAL" ] ], sent
    assert_equal :invalid_param, result[:error] if sent.empty?
    assert_empty @mock.received_calls if sent.empty?
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
    seed_happy
    # %DT takes years 1800-2699 only (DIDT.m:76); DATE^AGGUL1 turns the failure
    # into "" and FILE^DIE of a null .01 deletes the row (DIEF.m:56).
    [ "T", "T-1", "TODAY", "11/5/2026", "2026-11-05", "02/30/2026", "13/01/2026", "11/05/2026@1200",
      "01/01/1799", "12/31/2700", "11/05/1026", "01/01/0001", "01/01/9999" ].each do |bad|
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

  # The read proves ownership only when it is exactly one clean .02 row of
  # this file and this IENS holding the canonical DFN.
  def test_ownership_read_fails_closed_on_any_reply_that_is_not_one_clean_row
    seed_legl("1^^#{RIEN}")
    { "duplicate .02 rows" => [ "9000033^#{RIEN},^.02^#{DFN_B}^", "9000033^#{RIEN},^.02^#{DFN}^" ],
      "four-piece row" => [ "9000033^#{RIEN},^.02^#{DFN}" ],
      "row for IENS 7," => [ "9000033^7,^.02^#{DFN}^" ],
      "row for IENS without a comma" => [ "9000033^#{RIEN}^.02^#{DFN}^" ],
      "row for file 2" => [ "2^#{RIEN},^.02^#{DFN}^" ],
      "second row of another file" => [ "9000033^#{RIEN},^.02^#{DFN}^", "2^#{RIEN},^.01^SYNTH^" ],
      "altered reply" => [ "9000033^#{RIEN},^.02^#{DFN}^\xFF" ],
      "padded .02" => [ "9000033^#{RIEN},^.02^ #{DFN} ^" ],
      "non-canonical .02" => [ "9000033^#{RIEN},^.02^0#{DFN}^" ] }.each do |label, rows|
      seed_lines(GETS, gets_param(RIEN).to_s, [ "[Data]", *rows ])
      [ [ "D", {} ], [ "", EDIT ] ].each do |proc, params|
        assert_read_refusal :rien_unverified, "#{label} proc #{proc.inspect}", proc: proc, params: params
      end
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

  # A -1 or header-only reply can follow a partial write (AGGDATA is filed
  # before AGGDATAI), so once LEGL is sent a failure does not say "not written".
  def test_legl_rejection_row_is_agg_rejected_with_its_text_and_written_unknown
    seed_owner(RIEN, DFN)
    seed_legl("-1^AGGLNMC not a valid parameter for this update^^")

    result = Agg.update_legal_names(dfn: DFN, proc: "", rien: RIEN, params: EDIT)

    assert_equal({ success: false, error: :agg_rejected, message: "AGGLNMC not a valid parameter for this update",
                   written: :unknown }, result)
  end

  def test_header_only_legl_reply_is_agg_empty_reply_with_written_unknown
    seed_owner(RIEN, DFN)
    seed_lines(LEGL, DFN, "5\x00#{HEADER}#{RS}#{US}")

    result = Agg.update_legal_names(dfn: DFN, proc: "D", rien: RIEN, params: {})

    assert_kind_of String, result[:message]
    assert_equal({ success: false, error: :agg_empty_reply, written: :unknown }, result.except(:message))
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

  # A client with no synchronize_wire of its own is serialized by the module lock.
  def test_client_without_synchronize_wire_runs_read_and_legl_under_the_module_wire_lock
    client = Class.new do
      attr_reader :owned

      def call_rpc(rpc_name, *)
        (@owned ||= []) << [ rpc_name, RpmsRpc::MODULE_WIRE_LOCK.mon_owned? ]
        return [ "[Data]", "9000033^#{RIEN},^.02^#{DFN}^" ] if rpc_name == GETS

        "5\x00#{HEADER}#{RS}1^^#{RIEN}#{RS}#{US}"
      end
      alias_method :call_rpc_lines, :call_rpc
    end.new
    refute_respond_to client, :synchronize_wire

    result = Agg.update_legal_names(dfn: DFN, proc: "D", rien: RIEN, params: {}, client: client)

    assert_equal({ success: true, ien: 42 }, result)
    assert_equal [ [ GETS, true ], [ LEGL, true ] ], client.owned
  end

  def test_context_is_restored_after_a_success_and_after_an_ownership_refusal
    before = @mock.current_context
    seed_happy
    assert_equal true, Agg.update_legal_names(dfn: DFN, proc: "D", rien: RIEN, params: {})[:success]
    assert_equal before, @mock.current_context
    assert_equal [ DDR_CONTEXT, before, Agg::CONTEXT, before ], @mock.context_binds

    seed_owner(RIEN, DFN_B)
    @mock.context_binds.clear
    assert_equal :rien_not_for_dfn, Agg.update_legal_names(dfn: DFN, proc: "D", rien: RIEN, params: {})[:error]
    assert_equal before, @mock.current_context
    assert_equal [ DDR_CONTEXT, before ], @mock.context_binds
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

  # An object that is not a String but whose to_s is +text+.
  def to_s_object(text) = Object.new.tap { |o| o.define_singleton_method(:to_s) { text } }

  # An object whose to_s answers +first+ once and +later+ from then on.
  def flipping(first, later)
    asked = 0
    Object.new.tap { |o| o.define_singleton_method(:to_s) { (asked += 1) == 1 ? first : later } }
  end

  # The row is DFN's and LEGL answers success: a refusal is the wrapper's own.
  def seed_happy
    seed_owner(RIEN, DFN)
    seed_legl("1^^#{RIEN}")
  end

  def seed_lines(rpc, key, reply, mock: @mock)
    return mock.seed_raw_lines(MAPPINGS.fetch(rpc), key, reply) if reply.is_a?(Array)

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
    refute result.key?(:written), "#{label}: nothing was sent, so no :written"
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
    refute result.key?(:written), "#{label}: LEGL was not sent, so no :written"
  end
end
