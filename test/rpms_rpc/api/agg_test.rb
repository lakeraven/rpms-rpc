# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/agg"
require_relative "../captured_replies"

# Tests for RpmsRpc::Agg — the AG-package registration RPC surface
# (rpms-rpc#214). Each test replays what the pinned build sent PROFILE,REG on
# a throwaway container (test/fixtures/captured_replies/agg-registration.yml):
# a typed header row, then $C(30)-separated records. The add and update flows
# filed and edited a synthetic patient there; the DFN is the one it assigned.
class AggTest < Minitest::Test
  Agg = RpmsRpc::Agg
  SLUG = "agg-registration"
  FS = "\x1c" # $C(28)
  NEW = { "AGGPTLNM" => "SYNTHETIC", "AGGPTFNM" => "AGGADD", "AGGPTSEX" => "F", "AGGPTDOB" => "03/05/1902",
          "AGGPTSSN" => "900619001" }.freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow = nil, context: CapturedReplies::ReplayCiaClient::SIGNON_CONTEXT)
    @client = CapturedReplies::ReplayCiaClient.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {})
    @client.create_context(context) unless context == CapturedReplies::ReplayCiaClient::SIGNON_CONTEXT
    @client.calls.clear
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
  def binds = @client.calls.select { |c| c[:rpc] == :create_context }.map { |c| c[:params].first }
  def recorded(flow) = CapturedReplies.flow_calls(SLUG, flow)
  # A capture's reply, past the sequence echo and ack, as UTF-8 text.
  def body(flow) = CapturedReplies.raw(SLUG, "#{flow}/1").byteslice(2..).force_encoding(Encoding::UTF_8)

  # -- PARMS encoding --------------------------------------------------------

  def test_encode_parms_joins_name_value_pairs_with_fs
    assert_equal "AGGPTLNM=PROBE#{FS}AGGPTFNM=AGGONE", Agg.encode_parms("AGGPTLNM" => "PROBE", "AGGPTFNM" => "AGGONE")
  end

  def test_encode_parms_drops_nil_values
    encoded = Agg.encode_parms("AGGPTLNM" => "PROBE", "AGGPTMNM" => nil, "AGGPTSSN" => "")

    assert_equal "AGGPTLNM=PROBE#{FS}AGGPTSSN=", encoded, "nils dropped; empty strings kept"
  end

  # -- reply parsing ---------------------------------------------------------

  def test_parse_reply_maps_typed_header_names_onto_record_pieces
    parsed = Agg.parse_reply(body("add_ok"))

    assert_equal %i[result message dfn], parsed[:header]
    assert_equal [ { result: "1", message: "", dfn: "990060" } ], parsed[:records]
  end

  def test_parse_reply_strips_leading_sequence_echo_and_ack
    parsed = Agg.parse_reply(CapturedReplies.raw(SLUG, "add_ok/1"))

    assert_equal [ { result: "1", message: "", dfn: "990060" } ], parsed[:records]
  end

  def test_parse_reply_handles_multiple_records
    parsed = Agg.parse_reply(CapturedReplies.raw("agg-stock", "edit_check/1"))

    assert_operator parsed[:records].length, :>, 1
    assert_equal %w[WARNING], parsed[:records].map { |r| r[:type] }.uniq.first(1)
  end

  # BMX and XWB hand back an Array of lines, not a blob. BMX strips the $C(30)
  # row separator and the $C(31) sentinel (split_bmx_reply); a line array built
  # from the M nodes keeps them. Both must parse like the blob.
  def test_parse_reply_parses_a_line_array_with_separators_stripped
    parsed = Agg.parse_reply(body("add_ok").split("\x1e"))

    assert_equal [ { result: "1", message: "", dfn: "990060" } ], parsed[:records]
  end

  def test_parse_reply_parses_a_line_array_with_separators_kept
    parsed = Agg.parse_reply(body("add_ok").split(/(?<=\x1e)/))

    assert_equal [ { result: "1", message: "", dfn: "990060" } ], parsed[:records]
  end

  def test_parse_reply_nil_on_empty
    assert_nil Agg.parse_reply([])
    assert_nil Agg.parse_reply(nil)
    assert_nil Agg.parse_reply("")
  end

  # -- add_patient -----------------------------------------------------------

  def test_add_patient_success_returns_dfn_and_sends_window_dfn_and_encoded_parms
    replay("add_ok", context: "OR CPRS GUI CHART")

    assert_equal({ success: true, dfn: 990_060, message: "" }, Agg.add_patient(params: NEW))
    window, dfn, parms = sent.first.last
    assert_equal [ Agg::DEFAULT_WINDOW, "" ], [ window, dfn ]
    assert_equal "AGGPTLNM=SYNTHETIC#{FS}AGGPTFNM=AGGADD#{FS}AGGPTSEX=F#{FS}AGGPTDOB=03/05/1902#{FS}AGGPTSSN=900619001",
                 parms
    assert_equal recorded("add_ok"), sent
    assert_equal [ "AGGRPC", "OR CPRS GUI CHART" ], binds, "an AGG write is denied outside AGGRPC (CIANBACT.m:55)"
  end

  # ADD^AGGPTADD answers -1 with its reason for a window it does not have.
  def test_add_patient_rejection_returns_error_and_message
    replay("add_unknown_window")

    result = Agg.add_patient(window: "No Such Window", params: NEW)

    assert_equal({ success: false, error: :agg_rejected,
                   message: "RPC Failed: Passed in window name No Such Window not found" }, result)
  end

  # With an empty last name ADD^AGGPTADD files nothing and still answers RESULT
  # 1, with DFN -1 (AGGPTADD.m:119-121). That names no patient (rpms-rpc#878).
  def test_add_patient_reads_a_success_record_with_dfn_minus_one_as_no_patient
    replay("add_refused")

    result = Agg.add_patient(params: { "AGGPTLNM" => "" })

    refute result[:success]
    assert_equal :agg_malformed_reply, result[:error]
  end

  # -- AGG WINDOW DATA VALIDATION (VAL^AGGWVAL) ------------------------------

  def test_validate_field_reports_rpms_refusal_with_its_message
    replay("validate_ssn_taken")

    result = Agg.validate_field(window: Agg::NEW_PATIENT_WINDOW,
                                params: { "AGGPTSSN" => "666021001", "AGGNOSSN" => "", "DFN" => "" })

    assert_equal({ valid: false, message: "SSN already used by another patient." }, result)
    assert_equal [ [ "AGG WINDOW DATA VALIDATION", [ Agg::NEW_PATIENT_WINDOW, "AGGPTSSN=666021001#{FS}AGGNOSSN=#{FS}DFN=" ] ] ],
                 sent
  end

  def test_validate_field_one_is_not_a_refusal
    replay("validate_ssn_free")

    assert_equal({ valid: true }, Agg.validate_field(window: Agg::NEW_PATIENT_WINDOW,
                                                     params: { "AGGPTSSN" => "900619999", "AGGNOSSN" => "", "DFN" => "" }))
  end

  # The validator gives the header and no row when there is nothing it checks
  # (openrpms#1040): a no-SSN reason alone, or both blank. That is no answer.
  def test_validate_field_is_nil_when_rpms_gives_no_result_row
    replay("validate_no_ssn_reason")
    assert_nil Agg.validate_field(window: Agg::NEW_PATIENT_WINDOW, params: { "AGGNOSSN" => "R" })

    replay("validate_blank")
    assert_nil Agg.validate_field(window: Agg::NEW_PATIENT_WINDOW, params: { "AGGNOSSN" => "", "AGGPTSSN" => "" })
  end

  # -- AGG BUILD WINDOW DISPLAY (BLD^AGGWDISP) --------------------------------

  def test_window_values_reads_each_parameter_with_pointer_and_choice_pairs
    replay("window_personal")

    values = Agg.window_values(window: "Personal Detail", dfn: 990_031)

    assert_equal "EMBER,AVERY", values["PTNAME"]
    assert_equal "MAR 15,1997", values["AGGPTDOB"]
    assert_equal({ internal: "F", external: "FEMALE" }, values["AGGPTSEX"])
    assert_equal({ internal: nil, external: nil }, values["AGGPTMAR"])
    assert_equal "", values["AGGEMSTS"]
    assert_equal [ [ "AGG BUILD WINDOW DISPLAY", [ "Personal Detail", "990031" ] ] ], sent
    assert_equal [ "AGGRPC", "CIAV VUECENTRIC" ], binds
  end

  def test_window_values_for_no_patient_are_empty_and_an_unknown_window_is_nil
    replay("window_no_patient")
    values = Agg.window_values(window: "Personal Detail", dfn: 999_999_999)
    assert_equal [ "" ], values.values.uniq
    assert_equal "", values["AGGPTLNM"]

    replay("window_unknown")
    assert_nil Agg.window_values(window: "No Such Window", dfn: 990_031)
  end

  # -- update_patient (header without a DFN piece) ---------------------------

  def test_update_patient_success
    replay("update_ok")

    assert_equal({ success: true, dfn: nil, message: "" },
                 Agg.update_patient(dfn: 990_060, params: { "AGGPTMAR" => "NEVER MARRIED" }))
    assert_equal [ [ "AGG UPDATE PATIENT", [ Agg::DEFAULT_WINDOW, "990060", "AGGPTMAR=NEVER MARRIED" ] ] ], sent
  end

  def test_update_patient_rejection_uses_error_piece_as_message
    replay("update_not_on_file")

    result = Agg.update_patient(dfn: 999_999_999, params: { "AGGPTMAR" => "NEVER MARRIED" })

    assert_equal({ success: false, error: :agg_rejected, message: "The entry does not exist." }, result)
  end

  # The build answers 1 for a parameter the window does not have and for a date
  # of birth that is no date, on update and on add. The gem reads what was
  # sent; a caller that needs the value on file reads it back.
  def test_update_and_add_read_the_builds_one_for_a_value_it_did_not_check
    replay("update_refused")
    assert Agg.update_patient(dfn: 990_060, params: { "AGGNOSUCH" => "X" })[:success]

    replay("update_bad_dob")
    assert Agg.update_patient(dfn: 990_060, params: { "AGGPTDOB" => "13/45/1900" })[:success]

    replay("add_bad_dob")
    assert_equal 990_061, Agg.add_patient(params: NEW.merge("AGGPTFNM" => "AGGBADDOB", "AGGPTDOB" => "13/45/1900",
                                                            "AGGPTSSN" => "900619002"))[:dfn]
  end

  # -- temporary_hrn ---------------------------------------------------------

  # GTMP^AGGPTHRN (AGGPTHRN.m:5-17): P1 = DFN; header T00010AGGPTHRN, then
  # the next temporary number.
  def test_temporary_hrn_reads_the_number_for_the_patient_under_aggrpc
    replay("temp_hrn")

    assert_equal "T00003", Agg.temporary_hrn(dfn: 990_060)
    assert_equal [ [ "AGG GET TEMP PAT HRN", [ "990060" ] ] ], sent
    assert_equal [ "AGGRPC", "CIAV VUECENTRIC" ], binds
  end

  # GTMP^AGGPTHRN hands out the next number for a DFN no patient has, too: the
  # reply alone does not show the patient is on file.
  def test_temporary_hrn_answers_a_number_for_a_dfn_not_on_file
    replay("temp_hrn_no_patient")

    assert_equal "T00002", Agg.temporary_hrn(dfn: 999_999_999)
  end

  # -- edit_check ------------------------------------------------------------

  def test_edit_check_maps_all_seven_wire_columns
    client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script("agg-stock", "edit_check"))

    check = Agg.edit_check(dfn: 990_031, client: client)[:checks].first

    assert_equal({ hide_error_num: "37", msg: "INTERNET ACCESS INFORMATION PAST ONE YEAR", type: "WARNING",
                   hide_window: "Other Patient", hide_field: "AGGINTNT", hide_tab: "OtherPatientData", hide_key: "O" },
                 check)
    assert_equal [ [ "AGG PATIENT EDIT CHECK", [ "990031" ] ] ],
                 client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
  end

  # -- available? (CANRUN registry evidence, no side effects) ----------------
  #
  # The registered entry is CANRUN^CIANBRPC (CIANBRPC.m:173-175), which resolves
  # the #8994 IEN itself with $$FIND1^DIC(8994,,"QX",RPC), so P1 on the wire is
  # the RPC NAME. CANRUN answers a $DATA value (#367): 10 or 11 for a listed RPC
  # as a non-programmer, from the context bound right now (CIANBACT.m:148,155).
  # The AGG* RPCs are registered under AGGRPC only, so the probe binds it.

  def test_available_true_when_canrun_reports_ten
    replay("available", context: "OR CPRS GUI CHART")

    assert Agg.available?
    assert_equal [ [ "CIANBRPC CANRUN", [ "AGG ADD NEW PATIENT" ] ] ], sent,
                 "P1 must be the RPC NAME — CANRUN^CIANBRPC does the 8994 lookup itself"
    assert_equal [ "AGGRPC", "OR CPRS GUI CHART" ], binds,
                 "the gate is answered from the current context, and the caller's is restored"
  end

  # PROFILE,MD does not hold AGGRPC; CANRUN answers 0.
  def test_available_false_when_canrun_reports_zero
    replay("available_md")

    refute Agg.available?
  end

  def test_available_does_not_rebind_a_context_already_held
    replay("available", context: "AGGRPC")

    assert Agg.available?
    assert_empty binds, "no round trip when already bound"
  end
end
