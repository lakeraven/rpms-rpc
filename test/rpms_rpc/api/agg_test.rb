# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/agg"

# Tests for RpmsRpc::Agg — the AG-package registration RPC surface
# (rpms-rpc#214). Reply fixtures reproduce the layouts confirmed by the #214
# live probe: a typed header row, then $C(30)-separated records, ending
# $C(31). All data synthetic.
class AggTest < Minitest::Test
  Agg = RpmsRpc::Agg
  FS = "\x1c"  # $C(28)
  RS = "\x1e"  # $C(30)
  US = "\x1f"  # $C(31)

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # -- PARMS encoding --------------------------------------------------------

  def test_encode_parms_joins_name_value_pairs_with_fs
    encoded = Agg.encode_parms("AGGPTLNM" => "PROBE", "AGGPTFNM" => "AGGONE")

    assert_equal "AGGPTLNM=PROBE#{FS}AGGPTFNM=AGGONE", encoded
  end

  def test_encode_parms_drops_nil_values
    encoded = Agg.encode_parms("AGGPTLNM" => "PROBE", "AGGPTMNM" => nil, "AGGPTSSN" => "")

    assert_equal "AGGPTLNM=PROBE#{FS}AGGPTSSN=", encoded, "nils dropped; empty strings kept"
  end

  # -- reply parsing ---------------------------------------------------------

  def test_parse_reply_maps_typed_header_names_onto_record_pieces
    raw = "I00010RESULT^T00080MESSAGE^I00010DFN#{RS}1^^9#{RS}#{US}"

    parsed = Agg.parse_reply(raw)

    assert_equal %i[result message dfn], parsed[:header]
    assert_equal [ { result: "1", message: "", dfn: "9" } ], parsed[:records]
  end

  def test_parse_reply_strips_leading_sequence_echo_and_ack
    # A live CIA reply is prefixed by the 1-byte sequence echo and a \x00 ack.
    raw = "7\x00I00010RESULT^T00080MESSAGE^I00010DFN#{RS}1^^9#{RS}#{US}"

    parsed = Agg.parse_reply(raw)

    assert_equal [ { result: "1", message: "", dfn: "9" } ], parsed[:records]
  end

  def test_parse_reply_handles_multiple_records
    raw = "I00010N^T00030MSG^T00001TYPE#{RS}37^INCOMPLETE^WARNING#{RS}38^MISSING^MANDATORY#{RS}#{US}"

    parsed = Agg.parse_reply(raw)

    assert_equal 2, parsed[:records].length
    assert_equal "MANDATORY", parsed[:records].last[:type]
  end

  def test_parse_reply_nil_on_empty
    assert_nil Agg.parse_reply(nil)
    assert_nil Agg.parse_reply("")
  end

  # -- add_patient -----------------------------------------------------------

  def seed_add(reply)
    @mock.seed(:agg_add_patient, Agg::DEFAULT_WINDOW, reply)
  end

  def test_add_patient_success_returns_dfn
    seed_add("I00010RESULT^T00080MESSAGE^I00010DFN#{RS}1^^9#{RS}#{US}")

    result = Agg.add_patient(params: { "AGGPTLNM" => "PROBE" })

    assert result[:success]
    assert_equal 9, result[:dfn]
  end

  def test_add_patient_rejection_returns_error_and_message
    seed_add("I00010RESULT^T00080MESSAGE^I00010DFN#{RS}-1^NAME is required#{RS}#{US}")

    result = Agg.add_patient(params: { "AGGPTLNM" => "" })

    refute result[:success]
    assert_equal :agg_rejected, result[:error]
    assert_match(/NAME is required/, result[:message])
  end

  def test_add_patient_passes_window_dfn_and_encoded_parms
    seed_add("I00010RESULT^T00080MESSAGE^I00010DFN#{RS}1^^9#{RS}#{US}")

    Agg.add_patient(params: { "AGGPTLNM" => "PROBE", "AGGPTSEX" => "MALE" })

    call = @mock.received_calls.find { |c| c[:rpc] == "AGG ADD NEW PATIENT" }
    assert_equal Agg::DEFAULT_WINDOW, call[:params][0]
    assert_equal "", call[:params][1]
    assert_equal "AGGPTLNM=PROBE#{FS}AGGPTSEX=MALE", call[:params][2]
  end

  def test_add_patient_nil_when_no_broker_response
    assert_nil Agg.add_patient(params: { "AGGPTLNM" => "PROBE" })
  end

  # -- update_patient (header without a DFN piece) ---------------------------

  def test_update_patient_success
    @mock.seed(:agg_update_patient, Agg::DEFAULT_WINDOW,
      "I00010RESULT^T01024ERROR^T01024OTHER_PARMS#{RS}1^^#{RS}#{US}")

    result = Agg.update_patient(dfn: 9, params: { "AGGPTHRN" => "9" })

    assert result[:success]
    assert_nil result[:dfn], "UPDATE reply carries no DFN piece"
    call = @mock.received_calls.find { |c| c[:rpc] == "AGG UPDATE PATIENT" }
    assert_equal "9", call[:params][1]
  end

  def test_update_patient_rejection_uses_error_piece_as_message
    @mock.seed(:agg_update_patient, Agg::DEFAULT_WINDOW,
      "I00010RESULT^T01024ERROR^T01024OTHER_PARMS#{RS}-1^BAD FIELD^#{RS}#{US}")

    result = Agg.update_patient(dfn: 9, params: { "AGGPTHRN" => "9" })

    refute result[:success]
    assert_equal :agg_rejected, result[:error]
    assert_match(/BAD FIELD/, result[:message])
  end

  # -- edit_check ------------------------------------------------------------

  def test_edit_check_returns_the_validation_battery
    @mock.seed(:agg_patient_edit_check, "9",
      "I00010HIDE_ERROR_NUM^T00030MSG^T00001TYPE#{RS}" \
      "37^INTERNET ACCESS INFO^WARNING#{RS}40^HOMELESS INFO^MANDATORY#{RS}#{US}")

    result = Agg.edit_check(dfn: 9)

    assert_equal 2, result[:checks].length
    assert_equal "WARNING", result[:checks].first[:type]
    assert_equal "MANDATORY", result[:checks].last[:type]
  end

  # -- available? (CANRUN registry evidence, no side effects) ----------------

  def test_available_true_when_canrun_reports_one
    @mock.seed_scalar(:agg_canrun, "AGG ADD NEW PATIENT", "1")

    assert Agg.available?
  end

  def test_available_false_when_canrun_reports_zero
    @mock.seed_scalar(:agg_canrun, "AGG ADD NEW PATIENT", "0")

    refute Agg.available?
  end

  def test_available_false_when_rpc_absent
    # Nothing seeded — mock returns "".
    refute Agg.available?
  end

  # -- available? argument contract (rpms-rpc#225) ---------------------------
  #
  # The registered entry is "CIANBRPC CANRUN^CANRUN^CIANBRPC^1", i.e.
  # CANRUN^CIANBRPC (CIANBRPC.m:173-175), which resolves the file-8994 IEN
  # ITSELF with $$FIND1^DIC(8994,,"QX",RPC) and passes THAT to the
  # CANRUN^CIANBACT helper. So P1 on the wire must be the RPC NAME. These
  # tests pin that: sending an IEN instead would leave FIND1 unresolved ("",
  # DIC.m:102) and CANRUN^CIANBACT would quit 0 at CIANBACT.m:143.

  def test_available_sends_the_rpc_name_as_the_wire_argument
    @mock.seed_scalar(:agg_canrun, "AGG ADD NEW PATIENT", "1")

    Agg.available?

    call = @mock.received_calls.find { |c| c[:rpc] == "CIANBRPC CANRUN" }

    refute_nil call, "available? must probe CIANBRPC CANRUN"
    assert_equal [ "AGG ADD NEW PATIENT" ], call[:params],
      "P1 must be the RPC NAME — CANRUN^CIANBRPC does the 8994 lookup itself"
  end

  def test_available_false_when_the_gate_is_keyed_on_something_other_than_the_name
    # A gate keyed on a file-8994 IEN (a synthetic one) answers 1, but the
    # RPC name is unseeded. available? must still be false: it asks by name.
    @mock.seed_scalar(:agg_canrun, "31337", "1")

    refute Agg.available?,
      "an IEN-keyed gate must not satisfy a name-argument probe"
  end

  def test_available_false_when_a_different_agg_rpc_is_runnable
    # Presence of a DIFFERENT AGG RPC does not make the delegation path
    # available — the gate is per RPC name, per context option.
    @mock.seed_scalar(:agg_canrun, "AGG UPDATE PATIENT", "1")

    refute Agg.available?
  end

  # -- AGGRPC context binding (rpms-rpc#225) ---------------------------------
  #
  # RPC registration is OPTION-scoped, and the AGG* RPCs are registered under
  # AGGRPC only: ^DIC(19,13112,0)="AGGRPC^Patient Registration GUI^^B^…" with
  # AGG ADD NEW PATIENT (8994 IEN 3374) at ^DIC(19,13112,"RPC","B",3374,20).
  # They are absent from both contexts this gem can be sitting on — CIANB MAIN
  # MENU (#10976, the CIA sign-on AID, no RPC multiple at all) and OR CPRS GUI
  # CHART (#9649, 1004 RPCs, no 3374). CANRUN answers from the context bound
  # right now (CIANBACT.m:148,155), so without the bind every AGG call — the
  # availability probe included — is answered a truthful 0.

  def test_available_probes_the_gate_under_the_agg_context
    @mock.seed_scalar(:agg_canrun, "AGG ADD NEW PATIENT", "1")

    Agg.available?

    call = @mock.received_calls.find { |c| c[:rpc] == "CIANBRPC CANRUN" }

    refute_nil call, "available? must probe CIANBRPC CANRUN"
    assert_equal "AGGRPC", call[:context],
      "the gate is answered from the CURRENT context option — probing outside " \
      "AGGRPC asks a question whose answer is always 0"
  end

  def test_agg_writes_run_under_the_agg_context
    @mock.seed(:agg_add_patient, Agg::DEFAULT_WINDOW,
      "I00010RESULT^T00080MESSAGE^I00010DFN#{RS}1^^41#{RS}#{US}")

    Agg.add_patient(params: { "AGGPTLNM" => "PROBE" })

    call = @mock.received_calls.find { |c| c[:rpc] == "AGG ADD NEW PATIENT" }

    assert_equal "AGGRPC", call[:context],
      "an AGG write is denied outside AGGRPC (CIANBACT.m:55)"
  end

  def test_available_restores_the_callers_context
    @mock.create_context("OR CPRS GUI CHART")
    @mock.seed_scalar(:agg_canrun, "AGG ADD NEW PATIENT", "1")

    assert Agg.available?
    assert_equal "OR CPRS GUI CHART", @mock.current_context,
      "binding AGGRPC under a caller mid-workflow in another context must be undone"
    assert_equal [ "OR CPRS GUI CHART", "AGGRPC", "OR CPRS GUI CHART" ], @mock.context_binds
  end

  def test_available_does_not_rebind_a_context_already_held
    @mock.create_context("AGGRPC")
    @mock.seed_scalar(:agg_canrun, "AGG ADD NEW PATIENT", "1")

    assert Agg.available?
    assert_equal [ "AGGRPC" ], @mock.context_binds, "no round trip when already bound"
  end

  def test_available_false_and_warns_when_the_agg_context_will_not_bind
    # The broker refusing the option (not installed, or OPTCHK^CIANBUTL lock)
    # is exactly "AG is not usable here" — fall back, deliberately and loudly.
    @mock.unbindable_context!("AGGRPC")
    @mock.seed_scalar(:agg_canrun, "AGG ADD NEW PATIENT", "1")

    result = nil
    _out, err = capture_io { result = Agg.available? }

    refute result, "an unbindable AGGRPC must fail SAFE to the composition path"
    assert_match(/AGG delegation unavailable/, err, "the fallback must be logged, not silent")
  end
end
