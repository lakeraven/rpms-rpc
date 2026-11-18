# frozen_string_literal: true

require "minitest/autorun"
require "json"
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
    [ "d", "a", "X", " D", "DELETE", nil, :D, :A, 1 ].each do |bad|
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

  # A RIEN is an Integer or a String of 1 to 15 digits with no leading zero.
  def test_refuses_non_canonical_rien_without_rpc
    seed_owner(RIEN, DFN)
    seed_owner("1234567890123456", DFN)
    seed_legl("1^^#{RIEN}")
    [ "0", "042", "4 2", "-1", "abc", "1.5", "1234567890123456", 10**15, 0, -42,
      :"42", 42.0, [ 42 ], to_s_object(RIEN) ].each do |bad|
      assert_refused :invalid_rien, "rien #{bad.inspect}", dfn: DFN, proc: "D", rien: bad, params: {}
    end
  end

  def test_fifteen_digit_rien_is_read_and_sent
    rien = "9" * 15
    seed_owner(rien, DFN)
    seed_legl("1^^#{rien}")

    assert_equal({ success: true, ien: rien.to_i }, Agg.update_legal_names(dfn: DFN, proc: "D", rien: rien, params: {}))
    assert_equal [ gets_param(rien) ], @mock.received_calls.first[:params]
    assert_equal [ DFN, "D", rien, "" ], legl_call[:params]
  end

  # DFN, proc and RIEN are compared with a regexp or ==, which raise or
  # misjudge on a String that is not ASCII-compatible or not valid.
  def test_dfn_proc_and_rien_in_another_encoding_are_refused_without_raising
    seed_happy
    utf16 = ->(text) { text.encode("UTF-16LE") }
    [ utf16.(DFN), "#{DFN}\xFF", "#{DFN}\xFF".b ].each do |bad|
      assert_refused :invalid_dfn, "dfn #{bad.inspect}", dfn: bad, proc: "D", rien: RIEN, params: {}
    end
    [ utf16.("D"), "D\xFF", "D\xFF".b ].each do |bad|
      assert_refused :invalid_proc, "proc #{bad.inspect}", dfn: DFN, proc: bad, rien: RIEN, params: {}
    end
    [ utf16.(RIEN), "#{RIEN}\xFF", "#{RIEN}\xFF".b ].each do |bad|
      assert_refused :invalid_rien, "rien #{bad.inspect}", dfn: DFN, proc: "D", rien: bad, params: {}
    end
  end

  # What is validated is the String's bytes, so those bytes are what is sent:
  # a subclass whose to_s answers something else never puts that on the wire.
  def test_dfn_proc_and_rien_reach_the_wire_as_plain_strings_of_the_validated_bytes
    [ RIEN, "43" ].each { |rien| seed_owner(rien, DFN) }
    [ DFN, DFN_B ].each { |dfn| seed_legl("1^^#{RIEN}", dfn: dfn) }
    { dfn: masked(DFN, DFN_B), proc: masked("D", "A"), rien: masked(RIEN, "43") }.each do |name, value|
      @mock.received_calls.clear
      result = Agg.update_legal_names(**{ dfn: DFN, proc: "D", rien: RIEN, params: {} }.merge(name => value))

      if @mock.received_calls.empty?
        assert_equal [ false, :"invalid_#{name}" ], result.values_at(:success, :error), "#{name} refused"
      else
        assert_equal [ gets_param(RIEN) ], @mock.received_calls.first[:params], "#{name}: the read is of the validated RIEN"
        assert_equal [ DFN, "D", RIEN, "" ], legl_call[:params], "#{name}: validated bytes, not to_s"
        assert_equal({ success: true, ien: 42 }, result, name)
      end
    end
  end

  # AGGLNEBY's EXEC files DUZ whatever the value, and ALIASCK has no field:
  # both answer success while filing nothing the caller asked. AGGLNPRF (.04)
  # is a screened pointer to #9000030 that LEGL files unchecked.
  def test_legal_name_parms_allowlist_is_the_three_fields_legl_files_as_asked
    assert_equal %w[AGGLNDTC AGGLNMC AGGLGDOC], Agg::LEGAL_NAME_PARMS
  end

  def test_refuses_agglnprf_whatever_its_value
    seed_happy
    [ "AGGLNPRF", :AGGLNPRF ].each do |name|
      [ "7", 7 ].each do |value|
        [ "", "A" ].each do |proc|
          assert_refused :invalid_param, "#{name.inspect} => #{value.inspect} proc #{proc.inspect}",
                         dfn: DFN, proc: proc, rien: RIEN, params: { name => value }
        end
      end
    end
  end

  def test_refuses_agglneby_aliasck_and_keys_that_are_not_a_string_or_symbol
    seed_happy
    [ "AGGLNEBY", :AGGLNEBY, "ALIASCK", :ALIASCK, 7, to_s_object("AGGLNMC"), flipping("AGGLNMC", "RIEN") ].each do |name|
      assert_refused :invalid_param, "name #{name.inspect}", dfn: DFN, proc: "", rien: RIEN, params: { name => "SYNTH,LEGAL" }
    end
  end

  def test_refuses_values_that_are_not_a_string
    seed_happy
    [ [ "SYNTH,LEGAL" ], { "SYNTH" => "LEGAL" }, :SYNTH_LEGAL, 1.5, 12_345, to_s_object("SYNTH,LEGAL") ].each do |bad|
      assert_refused :invalid_param, "AGGLNMC #{bad.class}", dfn: DFN, proc: "", rien: RIEN, params: { "AGGLNMC" => bad }
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
  end

  # The wire carries bytes, so the bytes are what is checked, whatever the
  # String's encoding: each must be printable ASCII, 0x20-0x7E. 0x83 0x5E is
  # one Shift_JIS character whose second byte is "^".
  def test_refuses_any_value_byte_outside_printable_ascii_without_raising
    seed_happy
    [ "É" * 10, "SYN\u0085TH", "SYN TH", "SYNTH　", "SYNTH".encode("UTF-16LE"),
      "AB\x83\x5ECD".dup.force_encoding("Shift_JIS"), "\xFF\xFE".b, "SYN\xFFTH", "SYN\xFFTH".b ].each do |bad|
      %w[AGGLNMC AGGLGDOC AGGLNDTC].each do |name|
        assert_refused :invalid_param, "#{name} #{bad.encoding} #{bad.b.inspect}",
                       dfn: DFN, proc: "", rien: RIEN, params: { name => bad }
      end
    end
  end

  # A refusal is the shaped result of PUT /patients/{dfn}/agg/legal-names, so
  # it has to serialise: a key whose bytes are not UTF-8 is named in the
  # message by its inspect form, never by its raw bytes (rpms-rpc#627).
  def test_every_refusal_for_a_non_utf8_key_serialises_with_json_generate
    seed_happy
    keys = [ "\xFF".b, "\xC3".b, "AGG\xFFLNMC".b, "\xFF".b.to_sym, "AGG\xFFLNMC".b.to_sym,
             "\xFF".b.force_encoding(Encoding::Windows_1252), "\xFF".b.force_encoding(Encoding::UTF_8) ]
    keys.each do |key|
      shown = key.to_s.b.inspect
      [ nil, 5, :sym, 1.5, [ "SYNTH,LEGAL" ], "SYNTH,LEGAL" ].each do |value|
        [ { key => value }, { key => value, "AGGLNMC" => "SYNTH,LEGAL" }, { "AGGLNMC" => "SYNTH,LEGAL", key => value } ].each do |params|
          [ "A", "", "D" ].each do |proc|
            label = "proc #{proc.inspect} key #{key.class} #{key.encoding} #{shown} value #{value.inspect} of #{params.size}"
            result = assert_refused :invalid_param, label, dfn: DFN, proc: proc, rien: RIEN, params: params
            assert_serialisable_refusal result, label
            next if value.is_a?(String)

            assert_includes result[:message], shown, "#{label}: the message names the key by its inspect form"
          end
        end
      end
    end
  end

  def test_refuses_agglnmc_outside_3_to_45_and_agglgdoc_outside_3_to_20_bytes
    seed_happy
    { "AGGLNMC" => [ "AB", "A" * 46 ], "AGGLGDOC" => [ "AB", "A" * 21 ] }.each do |name, values|
      values.each do |bad|
        assert_refused :invalid_param, "#{name} of #{bad.size}", dfn: DFN, proc: "", rien: RIEN, params: { name => bad }
      end
    end
  end

  def test_sends_values_at_the_length_and_year_bounds
    seed_happy
    { { "AGGLNMC" => "ABC" } => "AGGLNMC=ABC", { "AGGLNMC" => "A" * 45 } => "AGGLNMC=#{'A' * 45}",
      { "AGGLGDOC" => "ABC" } => "AGGLGDOC=ABC", { AGGLGDOC: "A" * 20 } => "AGGLGDOC=#{'A' * 20}",
      { "AGGLNDTC" => "01/01/1800" } => "AGGLNDTC=01/01/1800",
      { "AGGLNDTC" => "12/31/2699" } => "AGGLNDTC=12/31/2699" }.each do |params, parms|
      @mock.received_calls.clear
      assert_equal({ success: true, ien: 42 }, Agg.update_legal_names(dfn: DFN, proc: "", rien: RIEN, params: params), parms)
      assert_equal [ DFN, "", RIEN, parms ], legl_call[:params]
    end
  end

  # The bytes validated are the bytes sent, never a String subclass's to_s:
  # "AGGLNMC=@" (a field delete) cannot reach the wire either way round.
  def test_a_value_is_validated_and_sent_as_its_bytes_not_its_to_s
    seed_happy
    result = Agg.update_legal_names(dfn: DFN, proc: "", rien: RIEN, params: { "AGGLNMC" => masked("SYNTH,LEGAL", "@") })

    assert_equal({ success: true, ien: 42 }, result)
    assert_equal [ DFN, "", RIEN, "AGGLNMC=SYNTH,LEGAL" ], legl_call[:params]

    assert_refused :invalid_param, "bytes @", dfn: DFN, proc: "", rien: RIEN, params: { "AGGLNMC" => masked("@", "SYNTH,LEGAL") }
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
    [ { "AGGLNMC" => "X", AGGLNMC: "Y" }, {}, { "AGGLNMC" => "X", "AGGLGDOC" => "Y" } ].each do |bad|
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
    seed_legl("1^^#{RIEN}")
    { "no reply" => nil, "error" => [ "[ERROR]" ], "malformed" => [ "garbage" ], "no .02 row" => [ "[Data]" ],
      "blank .02" => [ "[Data]", "9000033^#{RIEN}^.02^^" ] }.each do |label, lines|
      seed_lines(GETS, gets_param(RIEN).to_s, lines) if lines
      [ [ "D", {} ], [ "", EDIT ] ].each do |proc, params|
        assert_read_refusal :rien_unverified, "#{label} proc #{proc.inspect}", proc: proc, params: params
      end
    end
  end

  def test_row_of_another_patient_is_rien_not_for_dfn_without_legl
    seed_owner(RIEN, DFN_B)
    seed_legl("1^^#{RIEN}")
    [ [ "D", {} ], [ "A", EDIT ], [ "", EDIT ] ].each do |proc, params|
      assert_read_refusal :rien_not_for_dfn, "proc #{proc.inspect}", proc: proc, params: params
    end
  end

  # GETSC^DDR2 answers "[Data]" and then one row per field with the trailing
  # comma cut from the IENS (DDR2.m:32): 9000033^42^.02^990031^. The read
  # proves ownership only when it is exactly that: nothing before, between or
  # after, this file, this RIEN, five pieces with the last one empty.
  def test_ownership_read_fails_closed_on_any_reply_that_is_not_data_then_the_one_row
    seed_legl("1^^#{RIEN}")
    row = owner_row(RIEN, DFN)
    { "no [Data] line" => [ row ],
      "[ERROR] after the row" => [ "[Data]", row, "[ERROR]" ],
      "[Data] twice" => [ "[Data]", "[Data]", row ],
      "blank line after the row" => [ "[Data]", row, "" ],
      "extra .01 row after" => [ "[Data]", row, "9000033^#{RIEN}^.01^3261105^" ],
      "extra .01 row before" => [ "[Data]", "9000033^#{RIEN}^.01^3261105^", row ],
      "duplicate .02 rows" => [ "[Data]", row, row ],
      "two .02 rows, two owners" => [ "[Data]", owner_row(RIEN, DFN_B), row ],
      "second row of another file" => [ "[Data]", row, "2^#{RIEN}^.01^SYNTH^" ],
      "row for file 2" => [ "[Data]", "2^#{RIEN}^.02^#{DFN}^" ],
      "IENS with its comma" => [ "[Data]", "9000033^#{RIEN},^.02^#{DFN}^" ],
      "IENS 7" => [ "[Data]", owner_row("7", DFN) ],
      "IENS 042" => [ "[Data]", owner_row("0#{RIEN}", DFN) ],
      "row for field .01" => [ "[Data]", "9000033^#{RIEN}^.01^#{DFN}^" ],
      "four-piece row" => [ "[Data]", "9000033^#{RIEN}^.02^#{DFN}" ],
      "external piece filled" => [ "[Data]", "9000033^#{RIEN}^.02^#{DFN}^SYNTH,PATIENT" ],
      "six-piece row" => [ "[Data]", "9000033^#{RIEN}^.02^#{DFN}^^" ],
      "padded .02" => [ "[Data]", "9000033^#{RIEN}^.02^ #{DFN} ^" ],
      "non-canonical .02" => [ "[Data]", owner_row(RIEN, "0#{DFN}") ] }.each do |label, lines|
      seed_lines(GETS, gets_param(RIEN).to_s, lines)
      [ [ "D", {} ], [ "", EDIT ] ].each do |proc, params|
        assert_read_refusal :rien_unverified, "#{label} proc #{proc.inspect}", proc: proc, params: params
      end
    end
  end

  # The same two lines verify when the client did not alter them and do not
  # when it did: text the client had to repair is never proof of an owner.
  def test_ownership_read_the_client_marked_altered_is_unverified_though_its_lines_are_clean
    seed_legl("1^^#{RIEN}")
    clean = [ "[Data]", owner_row(RIEN, DFN) ]
    seed_lines(GETS, gets_param(RIEN).to_s, clean)
    assert_equal({ success: true, ien: 42 }, Agg.update_legal_names(dfn: DFN, proc: "D", rien: RIEN, params: {}))

    [ 0, 1 ].each do |index|
      seed_lines(GETS, gets_param(RIEN).to_s, RpmsRpc::Reply.from_wire(clean, altered: [ index ]))
      reply = @mock.call_rpc(GETS, gets_param(RIEN))
      assert RpmsRpc::Reply.altered?(reply), "the mock hands back the altered flag"
      assert_equal clean, RpmsRpc::DdrFileman.lines(reply)

      [ [ "D", {} ], [ "", EDIT ] ].each do |proc, params|
        assert_read_refusal :rien_unverified, "line #{index} altered, proc #{proc.inspect}", proc: proc, params: params
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
    seed_legl(nil)

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
        return [ "[Data]", "9000033^#{RIEN}^.02^#{DFN}^" ] if rpc_name == GETS

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

  # A String of +bytes+ whose to_s answers +shown+.
  def masked(bytes, shown) = Class.new(String) { define_method(:to_s) { shown } }.new(bytes)

  # The row is DFN's and LEGL answers success: a refusal is the wrapper's own.
  def seed_happy
    seed_owner(RIEN, DFN)
    seed_legl("1^^#{RIEN}")
  end

  def seed_lines(rpc, key, lines, mock: @mock)
    mock.seed_raw_lines(MAPPINGS.fetch(rpc), key, lines)
  end

  # GETSC^DDR2's row for the .02 of one entry: the IENS without its comma.
  def owner_row(rien, owner) = "9000033^#{rien}^.02^#{owner}^"

  def seed_owner(rien, owner, mock: @mock)
    seed_lines(GETS, gets_param(rien).to_s, [ "[Data]", owner_row(rien, owner) ], mock: mock)
  end

  # LEGL's reply as lines: the typed header, then +row+ (nil for header only).
  def seed_legl(row, dfn: DFN, mock: @mock)
    seed_lines(LEGL, dfn, [ HEADER, row ].compact, mock: mock)
  end

  # The one LEGL call, whose parameters are all plain Strings.
  def legl_call
    calls = @mock.received_calls.select { |c| c[:rpc] == LEGL }
    assert_equal 1, calls.size, "exactly one #{LEGL} call"
    calls.first[:params].each { |param| assert_instance_of String, param, "LEGL parameter #{param.inspect}" }
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

  # A refusal whose message is text JSON can carry: not binary, valid, and
  # generated without raising.
  def assert_serialisable_refusal(result, label)
    message = result[:message]
    json = begin
      JSON.generate(result)
    rescue JSON::GeneratorError, EncodingError => e
      flunk "#{label}: JSON.generate raised #{e.class}: #{e.message} for the message #{message.inspect}"
    end
    refute_equal Encoding::BINARY, message.encoding, "#{label}: the message is ASCII-8BIT (#{message.inspect})"
    assert message.valid_encoding?, "#{label}: the message is not valid #{message.encoding}"
    assert message.dup.force_encoding(Encoding::UTF_8).valid_encoding?, "#{label}: the message bytes are not UTF-8"
    assert_equal result[:message], JSON.parse(json).fetch("message"), "#{label}: the message survives JSON"
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
