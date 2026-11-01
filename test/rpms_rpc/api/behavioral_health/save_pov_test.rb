# frozen_string_literal: true

require "minitest/autorun"
require "delegate"
require "json"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/mappings"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/retry_safety"

# AMHG SAVE POV — POV^AMHGSVF (AMHGSVF.m:47-75), AXIS2/3/4/5, CLNPOV^AMHGEVF.
# Mock seeds use :amhg_save_pov → RPC "AMHG SAVE POV" (production mapping ships with #538).
# Mode piece is always E; eight pieces including blanks; CLNPOV replace-all on every call.
class BehavioralHealthSavePovTest < Minitest::Test
  BH = RpmsRpc::BehavioralHealth
  Ddr = RpmsRpc::DdrFileman
  RPC = "AMHG SAVE POV"
  RS = "\x1e" # $C(30)
  US = "\x1f" # $C(31)

  ROOT = File.expand_path("../../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  BH_VISIT_FILE = "9002011"
  POV_FILE = "9002011.01"
  POV_XREF = "AD"
  POV_FROM = "0"
  POV_FIELDS = ".01;.02;.03;.04E"
  POV_FLAGS = "IP"
  POV_MAX = "25"
  AXIS_IV_FILE = "9002011.06101"
  AXIS_IV_FIELDS = ".01"
  AXIS_IV_FLAGS = "IP"
  AXIS_IV_MAX = "25"
  MHSS_PROBLEM_FILE = "9002012.2"
  PSYCHOSOCIAL_FILE = "9002012.9"
  PRE_EDIT_VISIT_FIELDS = ".08;1112"
  PRE_EDIT_VISIT_FLAGS = "I"
  VISIT_AXIS_FIELDS = ".14;1115"
  VISIT_AXIS_FLAGS = "IE"
  AXIS_III_FIELD = "5301"
  AXIS_III_FLAGS = "E"
  PRE_POINTER_FIELDS = ".01"
  PRE_POINTER_FLAGS = "I"

  PATIENT = "990538"
  OTHER_PATIENT = "990539"
  RECORD_IEN = "8801"
  OTHER_RECORD_IEN = "8802"
  PROB_ONE = "501"
  PROB_TWO = "502"
  PROB_REPLACE = "503"
  AX4_ONE = "601"
  AX4_TWO = "602"
  AX4_REPLACE = "603"
  NARR_ONE = "SYNTH POV NARR A"
  NARR_TWO = "SYNTH POV NARR B"
  NARR_REPLACE = "SYNTH POV NARR C"
  AXIS_III_TEXT = "SYNTH AXIS III LINE"
  LONG_AXIS_III_SENT = ("SYNTH " * 24 + "SYNTHX" * 3).byteslice(0, 150).freeze
  AXIS_V = "55"
  GAF_TEXT = "12"
  AXIS_V_REPLACE = "70"

  WIRE_ONE_DIAGNOSIS =
    "E|#{RECORD_IEN}|#{PROB_ONE}~~#{NARR_ONE}|||#{AXIS_V}|#{PATIENT}|#{GAF_TEXT}".freeze

  FULL_KWARGS = {
    record_ien: RECORD_IEN,
    patient: PATIENT,
    diagnoses: [
      { problem: PROB_ONE, narrative: NARR_ONE },
      { problem: PROB_TWO, narrative: NARR_TWO }
    ],
    axis_iii: AXIS_III_TEXT,
    axis_iv: [ AX4_ONE, AX4_TWO ],
    axis_v: AXIS_V,
    gaf: GAF_TEXT
  }.freeze

  WIRE_FULL =
    "E|#{RECORD_IEN}|#{PROB_ONE}~~#{NARR_ONE}*#{PROB_TWO}~~#{NARR_TWO}|#{AXIS_III_TEXT}|" \
    "#{AX4_ONE}~~*#{AX4_TWO}~~|#{AXIS_V}|#{PATIENT}|#{GAF_TEXT}".freeze

  REPLACE_KWARGS = {
    record_ien: RECORD_IEN,
    patient: PATIENT,
    diagnoses: [ { problem: PROB_REPLACE, narrative: NARR_REPLACE } ],
    axis_iv: [ AX4_REPLACE ],
    axis_v: AXIS_V_REPLACE,
    gaf: "",
    axis_iii: ""
  }.freeze

  WIRE_REPLACE =
    "E|#{RECORD_IEN}|#{PROB_REPLACE}~~#{NARR_REPLACE}||#{AX4_REPLACE}~~|#{AXIS_V_REPLACE}|#{PATIENT}|".freeze

  ONE_KWARGS = {
    record_ien: RECORD_IEN,
    patient: PATIENT,
    diagnoses: [ { problem: PROB_ONE, narrative: NARR_ONE } ],
    axis_iv: [],
    axis_v: AXIS_V,
    gaf: GAF_TEXT
  }.freeze

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # --- wire shape (POV^AMHGSVF) --------------------------------------------

  def test_pins_exact_eight_piece_wire_for_one_diagnosis
    seed_success(WIRE_ONE_DIAGNOSIS, RECORD_IEN, **ONE_KWARGS)
    BH.save_pov(**ONE_KWARGS)

    call = save_call
    refute_nil call, "expected #{RPC}"
    assert_equal 1, call[:params].length
    assert_equal WIRE_ONE_DIAGNOSIS, call[:params].first
    assert_equal 8, call[:params].first.split("|", -1).length
    assert_equal "E", call[:params].first.split("|", -1)[0]
    assert_equal RPC, call[:rpc]
  end

  def test_pins_exact_eight_piece_wire_with_diagnoses_axis_iv_axis_iii_axis_v_and_gaf
    seed_success(WIRE_FULL, RECORD_IEN, **FULL_KWARGS)
    BH.save_pov(**FULL_KWARGS)

    param = save_call[:params].first
    assert_equal WIRE_FULL, param
    assert_equal 8, param.split("|", -1).length
  end

  def test_second_call_carries_only_the_new_wire_and_readback_shows_replace_all_not_patch
    seed_success(WIRE_FULL, RECORD_IEN, **FULL_KWARGS)
    BH.save_pov(**FULL_KWARGS)

    seed_success(WIRE_REPLACE, RECORD_IEN, **REPLACE_KWARGS, pov_rows: replace_pov_rows)
    BH.save_pov(**REPLACE_KWARGS)

    calls = amhg_calls
    assert_equal 2, calls.length
    assert_equal WIRE_REPLACE, calls.last[:params].first
    assert_pov_lister_ddr_after_second_call
  end

  def test_save_pov_runs_under_amhgrpc_and_restores_the_callers_context
    seed_success(WIRE_ONE_DIAGNOSIS, RECORD_IEN, **ONE_KWARGS)
    caller_context = @mock.current_context

    BH.save_pov(**ONE_KWARGS)

    call = save_call
    assert_equal "AMHGRPC", call[:context]
    assert_equal caller_context, @mock.current_context
    assert_equal [ "AMHGRPC", caller_context ], @mock.context_binds
  end

  def test_post_call_ddr_reads_do_not_run_under_amhgrpc_when_the_session_had_no_context
    seed_success(WIRE_ONE_DIAGNOSIS, RECORD_IEN, **ONE_KWARGS)
    @mock.instance_variable_set(:@current_context, nil)
    capture_io { BH.save_pov(**ONE_KWARGS) }

    save_index = @mock.received_calls.index { |c| c[:rpc] == RPC }
    refute_nil save_index
    after = @mock.received_calls[(save_index + 1)..].select { |c| c[:rpc].start_with?("DDR ") }
    refute_empty after
    after.each do |call|
      refute_equal "AMHGRPC", call[:context]
      refute_nil call[:context]
    end
  end

  def test_nil_context_save_pov_binds_exactly_amhgrpc_then_the_ddr_context
    seed_success(WIRE_ONE_DIAGNOSIS, RECORD_IEN, **ONE_KWARGS)
    @mock.instance_variable_set(:@current_context, nil)
    capture_io { BH.save_pov(**ONE_KWARGS) }

    assert_equal [ "AMHGRPC", "CIAV VUECENTRIC" ], @mock.context_binds
    assert_equal "CIAV VUECENTRIC", @mock.current_context
  end

  def test_nil_context_save_pov_rebinds_ddr_context_before_raising_on_bad_reply
    seed_pre_edit_and_pointers(**ONE_KWARGS)
    seed_reply(WIRE_ONE_DIAGNOSIS, pov_success_body("0"))
    @mock.instance_variable_set(:@current_context, nil)

    err = assert_raises(BH::SaveError) { capture_io { BH.save_pov(**ONE_KWARGS) } }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
    assert_equal [ "AMHGRPC", "CIAV VUECENTRIC" ], @mock.context_binds
  end

  def test_success_returns_the_record_ien_after_pre_edit_check_and_readback
    seed_success(WIRE_ONE_DIAGNOSIS, RECORD_IEN, **ONE_KWARGS)
    assert_equal RECORD_IEN, BH.save_pov(**ONE_KWARGS)
    assert_pre_edit_ddr_call("#{RECORD_IEN},")
    assert_pov_lister_ddr_call(RECORD_IEN)
  end

  def test_succeeds_with_v1_shaped_pov_and_axis_iv_lister_readback
    kwargs = ONE_KWARGS.merge(axis_iv: [ AX4_ONE ])
    wire = WIRE_ONE_DIAGNOSIS.sub("|||", "||#{AX4_ONE}~~|")
    rows = pov_rows_for(**kwargs)
    seed_success(
      wire, RECORD_IEN, **kwargs,
      pov_lister_reply: pov_lister_body_v1(rows),
      axis_iv_lister_reply: axis_iv_lister_body_v1([ AX4_ONE ])
    )
    assert_equal RECORD_IEN, BH.save_pov(**kwargs)
  end

  def test_raises_when_v1_pov_lister_data_section_has_no_sent_row
    body = "[BEGIN_diDATA]\n[END_diDATA]"
    assert_post_call_readback_miss(**ONE_KWARGS, pov_lister_reply: body)
  end

  def test_pins_pre_edit_visit_ddr_gets_fields_and_flags
    seed_success(WIRE_ONE_DIAGNOSIS, RECORD_IEN, **ONE_KWARGS)
    BH.save_pov(**ONE_KWARGS)

    param = pre_edit_ddr_param
    assert_equal PRE_EDIT_VISIT_FIELDS, param["FIELDS"]
    assert_equal PRE_EDIT_VISIT_FLAGS, param["FLAGS"]
    assert_equal "#{RECORD_IEN},", param["IENS"]
  end

  def test_pins_pre_amhg_pointer_ddr_gets_for_each_problem_and_axis_iv_ien
    seed_success(WIRE_FULL, RECORD_IEN, **FULL_KWARGS)
    BH.save_pov(**FULL_KWARGS)

    amhg_index = positions_of { |c| c[:rpc] == RPC }.first
    [ PROB_ONE, PROB_TWO ].each do |prob|
      idx = pointer_gets_index(MHSS_PROBLEM_FILE, prob)
      refute_nil idx
      assert_operator idx, :<, amhg_index
    end
    [ AX4_ONE, AX4_TWO ].each do |ax4|
      idx = pointer_gets_index(PSYCHOSOCIAL_FILE, ax4)
      refute_nil idx
      assert_operator idx, :<, amhg_index
    end
  end

  # --- pre-call refusals (no RPC) -------------------------------------------

  def test_save_error_is_a_subclass_of_rpms_rpc_error
    assert_operator BH::SaveError, :<, RpmsRpc::Error
  end

  def test_refuses_empty_or_missing_diagnoses_without_rpc
    base = ONE_KWARGS.merge(diagnoses: [ { problem: PROB_ONE, narrative: NARR_ONE } ])
    assert_input_validation_refusal(/diagnos/i, **base.merge(diagnoses: []))
    assert_input_validation_refusal(/diagnos/i, **base.merge(diagnoses: nil))
  end

  def test_refuses_blank_or_invalid_diagnosis_entries_without_rpc
    base = ONE_KWARGS
    assert_input_validation_refusal(/narrative/i,
                                   **base.merge(diagnoses: [ { problem: PROB_ONE, narrative: "" } ]))
    assert_input_validation_refusal(/problem/i,
                                   **base.merge(diagnoses: [ { problem: "0", narrative: NARR_ONE } ]))
    assert_input_validation_refusal(/problem/i,
                                   **base.merge(diagnoses: [ { problem: "abc", narrative: NARR_ONE } ]))
  end

  def test_refuses_duplicate_problem_iens_without_rpc
    dup = [
      { problem: PROB_ONE, narrative: NARR_ONE },
      { problem: PROB_ONE, narrative: "OTHER NARR" }
    ]
    assert_input_validation_refusal(/problem|diagnos/i, **ONE_KWARGS.merge(diagnoses: dup))
  end

  def test_refuses_duplicate_axis_iv_iens_without_rpc
    assert_input_validation_refusal(/axis iv/i, **FULL_KWARGS.merge(axis_iv: [ AX4_ONE, AX4_ONE ]))
  end

  def test_refuses_missing_axis_iv_keyword_without_rpc
    kwargs = ONE_KWARGS.dup
    kwargs.delete(:axis_iv)
    assert_empty amhg_calls
    BH.save_pov(**kwargs)
    flunk "expected ArgumentError for missing axis_iv keyword"
  rescue ArgumentError
    assert_empty amhg_calls
  end

  def test_refuses_nil_axis_v_without_rpc
    assert_input_validation_refusal(/axis v is required/i, **ONE_KWARGS.merge(axis_v: nil))
  end

  def test_refuses_nil_gaf_without_rpc
    assert_input_validation_refusal(/gaf is required/i, **ONE_KWARGS.merge(gaf: nil))
  end

  def test_allows_blank_axis_v_and_gaf_on_the_wire_to_clear
    wire = WIRE_ONE_DIAGNOSIS.sub("|#{AXIS_V}|#{PATIENT}|#{GAF_TEXT}", "||#{PATIENT}|")
    kwargs = ONE_KWARGS.merge(axis_v: "", gaf: "")
    seed_success(wire, RECORD_IEN, **kwargs, axis_v: "", gaf: "")
    BH.save_pov(**kwargs)
    assert_equal wire, save_call[:params].first
  end

  def test_refuses_invalid_record_ien_or_patient_without_rpc
    assert_input_validation_refusal(/record ien must be a positive integer/i,
                                   **ONE_KWARGS.merge(record_ien: "0"))
    assert_input_validation_refusal(/record ien must be a positive integer/i,
                                   **ONE_KWARGS.merge(record_ien: "abc"))
    assert_input_validation_refusal(/patient must be a positive integer/i, **ONE_KWARGS.merge(patient: "0"))
    assert_input_validation_refusal(/patient is required/i, **ONE_KWARGS.merge(patient: nil))
  end

  def test_refuses_when_pre_edit_patient_differs_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, OTHER_PATIENT)
    seed_pointer_exists(MHSS_PROBLEM_FILE, PROB_ONE)
    assert_pre_call_refusal(**ONE_KWARGS)
    assert_empty amhg_calls
  end

  def test_refuses_when_visit_is_signed_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT, signed: true)
    seed_pointer_exists(MHSS_PROBLEM_FILE, PROB_ONE)
    err = assert_raises(BH::SaveError) { BH.save_pov(**ONE_KWARGS) }
    assert_match(/signed/i, err.message)
    assert_empty amhg_calls
  end

  def test_refuses_pipe_tilde_star_caret_and_control_characters_without_rpc
    separators = [ "|", "~", "*", "^", RS, US, "\x01", "ok\nbad" ]
    separators.each do |bad|
      assert_input_validation_refusal(/separator|control/i,
                                      **ONE_KWARGS.merge(diagnoses: [ { problem: PROB_ONE, narrative: bad } ]))
    end
  end

  def test_refuses_whitespace_only_axis_v_gaf_axis_iii_and_narrative_without_rpc
    assert_input_validation_refusal(/axis v/i, **ONE_KWARGS.merge(axis_v: "   "))
    assert_input_validation_refusal(/gaf/i, **ONE_KWARGS.merge(gaf: "   "))
    assert_input_validation_refusal(/axis iii/i, **ONE_KWARGS.merge(axis_iii: "   "))
    assert_input_validation_refusal(/narrative/i,
                                   **ONE_KWARGS.merge(diagnoses: [ { problem: PROB_ONE, narrative: "  " } ]))
  end

  def test_refuses_more_than_twenty_five_diagnoses_or_axis_iv_entries_without_rpc
    problems = (501..526).map { |n| { problem: n.to_s, narrative: "SYNTH NARR #{n}" } }
    assert_input_validation_refusal(/diagnos|25/i, **ONE_KWARGS.merge(diagnoses: problems))
    axis_iv = (601..626).map(&:to_s)
    assert_input_validation_refusal(/axis iv|25/i, **FULL_KWARGS.merge(axis_iv: axis_iv))
  end

  def test_refuses_narrative_outside_fndnarr_input_transform_without_rpc
    assert_input_validation_refusal(/narrative/i,
                                   **ONE_KWARGS.merge(diagnoses: [ { problem: PROB_ONE, narrative: "X" } ]))
    long = "N" * 161
    assert_input_validation_refusal(/narrative/i,
                                   **ONE_KWARGS.merge(diagnoses: [ { problem: PROB_ONE, narrative: long } ]))
    assert_input_validation_refusal(/narrative/i,
                                   **ONE_KWARGS.merge(diagnoses: [ { problem: PROB_ONE, narrative: "-SYNTH" } ]))
    assert_input_validation_refusal(/narrative/i,
                                   **ONE_KWARGS.merge(diagnoses: [ { problem: PROB_ONE, narrative: ".SYNTH" } ]))
    assert_input_validation_refusal(/narrative|utf-8|ascii/i,
                                   **ONE_KWARGS.merge(diagnoses: [ { problem: PROB_ONE, narrative: "SYN\u0085TH" } ]))
    latin1 = "AB".dup + "caf\xE9".b
    assert_input_validation_refusal(/narrative|utf-8/i,
                                   **ONE_KWARGS.merge(diagnoses: [ { problem: PROB_ONE, narrative: latin1 } ]))
  end

  def test_refuses_c1_control_characters_in_free_text_without_rpc
    c1 = "\u0085"
    assert_input_validation_refusal(/gaf|control|separator/i, **ONE_KWARGS.merge(gaf: "12#{c1}"))
    assert_input_validation_refusal(/axis iii|control|separator/i, **ONE_KWARGS.merge(axis_iii: "SYN#{c1}TH"))
    assert_input_validation_refusal(/narrative|control|separator/i,
                                   **ONE_KWARGS.merge(diagnoses: [ { problem: PROB_ONE, narrative: "SYN#{c1}TH" } ]))
  end

  def test_refuses_at_sign_only_narrative_after_strip_without_rpc
    assert_input_validation_refusal(/delete marker/i,
                                   **ONE_KWARGS.merge(diagnoses: [ { problem: PROB_ONE, narrative: "@" } ]))
  end

  def test_refuses_at_sign_only_gaf_or_axis_iii_after_strip_without_rpc
    assert_input_validation_refusal(/delete marker/i, **ONE_KWARGS.merge(gaf: "@"))
    assert_input_validation_refusal(/delete marker/i, **ONE_KWARGS.merge(axis_iii: "@"))
    assert_input_validation_refusal(/delete marker/i, **ONE_KWARGS.merge(axis_iii: " @ "))
  end

  def test_refuses_invalid_axis_v_without_rpc
    assert_input_validation_refusal(/axis v/i, **ONE_KWARGS.merge(axis_v: 101))
    assert_input_validation_refusal(/axis v/i, **ONE_KWARGS.merge(axis_v: -1))
    assert_input_validation_refusal(/axis v/i, **ONE_KWARGS.merge(axis_v: "5.5"))
    assert_input_validation_refusal(/axis v/i, **ONE_KWARGS.merge(axis_v: "abc"))
  end

  def test_refuses_gaf_longer_than_twenty_bytes_without_rpc
    assert_input_validation_refusal(/gaf/i, **ONE_KWARGS.merge(gaf: "x" * 21))
  end

  def test_refuses_axis_iii_longer_than_245_bytes_or_with_newline_without_rpc
    assert_input_validation_refusal(/axis iii/i, **ONE_KWARGS.merge(axis_iii: "x" * 246))
    assert_input_validation_refusal(/axis iii|control|separator/i,
                                   **ONE_KWARGS.merge(axis_iii: "line one\nline two"))
  end

  def test_refuses_invalid_utf8_and_latin1_tagged_strings_without_rpc
    invalid = String.new("\xC0\x80", encoding: Encoding::ASCII_8BIT)
    assert_raises(BH::SaveError) { BH.save_pov(**ONE_KWARGS.merge(gaf: invalid)) }
    assert_empty amhg_calls
    latin1 = "SYNTH caf\xE9".dup.force_encoding(Encoding::ISO_8859_1)
    assert_input_validation_refusal(/not valid UTF-8/i, **ONE_KWARGS.merge(axis_iii: latin1))
  end

  def test_non_string_with_invalid_to_s_raises_save_error_without_rpc
    bad = Object.new
    bad.define_singleton_method(:to_s) { "\xFF".b }
    assert_raises(BH::SaveError) { BH.save_pov(**ONE_KWARGS.merge(axis_v: bad)) }
    assert_empty amhg_calls
  end

  def test_refuses_each_omitted_required_keyword_without_rpc
    base = ONE_KWARGS.dup
    %i[record_ien patient diagnoses axis_iv axis_v gaf].each do |key|
      kwargs = base.dup
      kwargs.delete(key)
      assert_empty amhg_calls
      assert_raises(ArgumentError) { BH.save_pov(**kwargs) }
      assert_empty amhg_calls
    end
  end

  def test_refuses_bad_integer_tokens_for_record_patient_problem_and_axis_iv_without_rpc
    assert_input_validation_refusal(/record ien must be a positive integer/i, **ONE_KWARGS.merge(record_ien: "0"))
    assert_input_validation_refusal(/record ien must be a positive integer/i, **ONE_KWARGS.merge(record_ien: "-1"))
    assert_input_validation_refusal(/record ien must be a positive integer/i, **ONE_KWARGS.merge(record_ien: "01"))
    assert_input_validation_refusal(/record ien must be a positive integer/i, **ONE_KWARGS.merge(record_ien: "1.5"))
    assert_input_validation_refusal(/record ien is required/i, **ONE_KWARGS.merge(record_ien: ""))
    assert_input_validation_refusal(/patient must be a positive integer/i, **ONE_KWARGS.merge(patient: "-1"))
    assert_input_validation_refusal(/patient must be a positive integer/i, **ONE_KWARGS.merge(patient: "01"))
    assert_input_validation_refusal(/patient must be a positive integer/i, **ONE_KWARGS.merge(patient: "1.5"))
    assert_input_validation_refusal(/patient is required/i, **ONE_KWARGS.merge(patient: ""))
    assert_input_validation_refusal(/problem must be a positive integer/i,
                                   **ONE_KWARGS.merge(diagnoses: [ { problem: "-1", narrative: NARR_ONE } ]))
    assert_input_validation_refusal(/problem must be a positive integer/i,
                                   **ONE_KWARGS.merge(diagnoses: [ { problem: "01", narrative: NARR_ONE } ]))
    assert_input_validation_refusal(/problem must be a positive integer/i,
                                   **ONE_KWARGS.merge(diagnoses: [ { problem: "1.5", narrative: NARR_ONE } ]))
    assert_input_validation_refusal(/axis iv must be a positive integer/i, **FULL_KWARGS.merge(axis_iv: [ "0" ]))
    assert_input_validation_refusal(/axis iv must be a positive integer/i, **FULL_KWARGS.merge(axis_iv: [ "-1" ]))
    assert_input_validation_refusal(/axis iv must be a positive integer/i, **FULL_KWARGS.merge(axis_iv: [ "01" ]))
    assert_input_validation_refusal(/axis iv must be a positive integer/i, **FULL_KWARGS.merge(axis_iv: [ "1.5" ]))
  end

  def test_refuses_when_problem_pointer_read_errors_or_is_empty_or_blank_dot01_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_pointer_exists(MHSS_PROBLEM_FILE, PROB_ONE, error: true)
    assert_pre_call_refusal(**ONE_KWARGS)
    seed_pointer_exists(MHSS_PROBLEM_FILE, PROB_ONE, empty: true)
    assert_pre_call_refusal(**ONE_KWARGS)
    seed_pointer_exists(MHSS_PROBLEM_FILE, PROB_ONE, blank_dot01: true)
    assert_pre_call_refusal(**ONE_KWARGS)
  end

  def test_refuses_when_problem_pointer_read_returns_nil_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    err = assert_pre_call_refusal(**ONE_KWARGS)
    assert_match(/problem/i, err.message)
  end

  def test_refuses_when_axis_iv_pointer_read_errors_or_is_empty_or_blank_dot01_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_pointer_exists(MHSS_PROBLEM_FILE, PROB_ONE)
    seed_pointer_exists(MHSS_PROBLEM_FILE, PROB_TWO)
    kwargs = FULL_KWARGS.merge(axis_iv: [ AX4_ONE ])
    seed_pointer_exists(PSYCHOSOCIAL_FILE, AX4_ONE, error: true)
    err = assert_pre_call_refusal(**kwargs)
    assert_match(/axis iv/i, err.message)
    seed_pointer_exists(PSYCHOSOCIAL_FILE, AX4_ONE, empty: true)
    err = assert_pre_call_refusal(**kwargs)
    assert_match(/axis iv/i, err.message)
    seed_pointer_exists(PSYCHOSOCIAL_FILE, AX4_ONE, blank_dot01: true)
    err = assert_pre_call_refusal(**kwargs)
    assert_match(/axis iv/i, err.message)
  end

  def test_refuses_when_record_pre_read_is_nil_empty_or_missing_1112_without_amhg_rpc
    seed_pointer_exists(MHSS_PROBLEM_FILE, PROB_ONE)
    assert_pre_call_refusal(**ONE_KWARGS)
    seed_pre_edit_patient(RECORD_IEN, PATIENT, empty: true)
    assert_pre_call_refusal(**ONE_KWARGS)
    seed_pre_edit_patient(RECORD_IEN, PATIENT, missing_1112: true)
    assert_pre_call_refusal(**ONE_KWARGS)
  end

  def test_refuses_when_record_pre_read_errors_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT, error: true)
    seed_pointer_exists(MHSS_PROBLEM_FILE, PROB_ONE)
    assert_pre_call_refusal(**ONE_KWARGS)
  end

  def test_blank_axis_iii_nil_or_empty_does_not_require_5301_readback
    seed_success(WIRE_ONE_DIAGNOSIS, RECORD_IEN, **ONE_KWARGS)
    BH.save_pov(**ONE_KWARGS)
    save_index = @mock.received_calls.index { |c| c[:rpc] == RPC }
    after = @mock.received_calls[(save_index + 1)..]
    wp_reads = after.select do |c|
      next false unless c[:rpc] == "DDR GETS ENTRY DATA"

      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["FIELDS"].to_s.include?(AXIS_III_FIELD)
    end
    assert_empty wp_reads, "blank axis III must not trigger 5301 read-back"

    seed_success(WIRE_ONE_DIAGNOSIS, RECORD_IEN, **ONE_KWARGS.merge(axis_iii: ""))
    BH.save_pov(**ONE_KWARGS.merge(axis_iii: ""))
    save_index = @mock.received_calls.rindex { |c| c[:rpc] == RPC }
    after = @mock.received_calls[(save_index + 1)..]
    wp_reads = after.select do |c|
      next false unless c[:rpc] == "DDR GETS ENTRY DATA"

      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["FIELDS"].to_s.include?(AXIS_III_FIELD)
    end
    assert_empty wp_reads
  end

  # --- post-call failures ---------------------------------------------------

  def test_raises_when_reply_is_not_the_record_ien
    seed_pre_edit_and_pointers(**ONE_KWARGS)
    seed_reply(WIRE_ONE_DIAGNOSIS, pov_success_body("0~Add POV"))
    err = assert_raises(BH::SaveError) { BH.save_pov(**ONE_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
  end

  def test_raises_outcome_unknown_when_reply_names_a_different_positive_record_ien
    seed_pre_edit_and_pointers(**ONE_KWARGS)
    seed_reply(WIRE_ONE_DIAGNOSIS, pov_success_body(OTHER_RECORD_IEN))
    seed_post_readback(RECORD_IEN, **ONE_KWARGS)
    err = assert_raises(BH::SaveError) { BH.save_pov(**ONE_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
  end

  def test_raises_when_reply_is_add_axis_iv_error_string
    seed_pre_edit_and_pointers(**FULL_KWARGS)
    seed_reply(WIRE_FULL, pov_success_body("0~Add Axis IV"))
    err = assert_raises(BH::SaveError) { BH.save_pov(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
  end

  def test_raises_on_m_error_row
    seed_pre_edit_and_pointers(**ONE_KWARGS)
    seed_reply(WIRE_ONE_DIAGNOSIS, "M ERROR|synthetic trap#{RS}#{US}")
    err = assert_raises(BH::SaveError) { BH.save_pov(**ONE_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
  end

  def test_amhg_connection_error_becomes_save_error_with_ambiguous_outcome
    seed_pre_edit_and_pointers(**ONE_KWARGS)
    wrapper = ConnectionErrorOnAmhgSavePov.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_pov(**ONE_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
    assert_kind_of RpmsRpc::Client::ConnectionError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_amhg_rpc_m_error_becomes_save_error_with_ambiguous_outcome
    seed_pre_edit_and_pointers(**ONE_KWARGS)
    wrapper = RpcMErrorOnAmhgSavePov.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_pov(**ONE_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
    assert_kind_of RpmsRpc::Client::RpcMError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_amhg_rpc_not_available_error_is_not_wrapped
    seed_pre_edit_and_pointers(**ONE_KWARGS)
    wrapper = RpcNotAvailableOnAmhgSavePov.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    assert_raises(RpmsRpc::Client::RpcNotAvailableError) { BH.save_pov(**ONE_KWARGS) }
    assert_empty amhg_calls
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_raises_when_sent_diagnosis_missing_from_pov_lister
    assert_post_call_readback_miss(**ONE_KWARGS, pov_rows: [])
  end

  def test_raises_when_extra_stale_pov_row_remains_after_replace
    rows = pov_rows_for(**ONE_KWARGS) + [ {
      ien: "9", problem: PROB_TWO, patient: PATIENT, record: RECORD_IEN, narrative_ext: NARR_TWO
    } ]
    assert_post_call_readback_miss(**ONE_KWARGS, pov_rows: rows)
  end

  def test_raises_when_narrative_external_text_differs_from_sent_value
    rows = pov_rows_for(**ONE_KWARGS)
    rows.first[:narrative_ext] = "PARTIAL FNDNARR MATCH ONLY"
    assert_post_call_readback_miss(**ONE_KWARGS, pov_rows: rows)
  end

  def test_raises_when_pov_row_patient_differs_from_sent_patient
    rows = pov_rows_for(**ONE_KWARGS)
    rows.first[:patient] = OTHER_PATIENT
    assert_post_call_readback_miss(**ONE_KWARGS, pov_rows: rows)
  end

  def test_ignores_pov_lister_rows_for_another_record_and_succeeds
    rows = pov_rows_for(**ONE_KWARGS) + [ {
      ien: "99", problem: "999", patient: PATIENT, record: OTHER_RECORD_IEN,
      narrative_ext: "FOREIGN RECORD ROW"
    } ]
    seed_success(WIRE_ONE_DIAGNOSIS, RECORD_IEN, **ONE_KWARGS, pov_rows: rows)
    assert_equal RECORD_IEN, BH.save_pov(**ONE_KWARGS)
  end

  def test_raises_when_pov_ddr_lister_reports_more
    assert_post_call_readback_miss(**ONE_KWARGS, lister_more: true)
  end

  def test_raises_when_pov_ddr_lister_errors
    assert_post_call_readback_miss(**ONE_KWARGS, lister_error: true)
  end

  def test_raises_when_axis_iv_clear_readback_has_no_data_marker
    clear_iv = ONE_KWARGS.merge(axis_iv: [])
    wire = WIRE_ONE_DIAGNOSIS
    assert_post_call_readback_miss(**clear_iv, wire: wire, axis_iv_lister_reply: "[Misc]")
  end

  def test_raises_when_pov_lister_reply_has_no_data_marker
    assert_post_call_readback_miss(**ONE_KWARGS, pov_lister_reply: "SYNTHETIC BROKER NOISE")
  end

  def test_raises_when_pov_lister_includes_malformed_extra_row
    good = pov_rows_for(**ONE_KWARGS).first
    body =
      "[Data]\n#{good[:ien]}^#{good[:problem]}^#{good[:patient]}^#{good[:record]}^#{good[:narrative_ext]}\n" \
      "2^#{PROB_TWO}^#{PATIENT}"
    assert_post_call_readback_miss(**ONE_KWARGS, pov_lister_reply: body)
  end

  def test_raises_when_axis_iv_lister_includes_row_with_blank_dot01
    kwargs = ONE_KWARGS.merge(axis_iv: [ AX4_ONE ])
    wire = WIRE_ONE_DIAGNOSIS.sub("|||", "||#{AX4_ONE}~~|")
    body = "[Data]\n1^#{AX4_ONE}\n2^"
    assert_post_call_readback_miss(**kwargs, wire: wire, axis_iv_lister_reply: body)
  end

  def test_raises_when_pov_readback_lists_the_same_sent_row_twice
    row = pov_rows_for(**ONE_KWARGS).first
    body = pov_lister_body([ row, row.merge(ien: "2") ])
    assert_post_call_readback_miss(**ONE_KWARGS, pov_lister_reply: body)
  end

  def test_raises_when_axis_iv_readback_lists_the_same_sent_ien_twice
    kwargs = ONE_KWARGS.merge(axis_iv: [ AX4_ONE ])
    wire = WIRE_ONE_DIAGNOSIS.sub("|||", "||#{AX4_ONE}~~|")
    body = "[Data]\n1^#{AX4_ONE}\n2^#{AX4_ONE}"
    assert_post_call_readback_miss(**kwargs, wire: wire, axis_iv_lister_reply: body)
  end

  def test_raises_when_axis_iv_row_is_missing_from_readback
    seed_pre_edit_and_pointers(**FULL_KWARGS)
    seed_reply(WIRE_FULL, pov_success_body(RECORD_IEN))
    seed_post_readback(RECORD_IEN, **FULL_KWARGS, axis_iv_lister: [])
    err = assert_raises(BH::SaveError) { BH.save_pov(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
  end

  def test_raises_when_extra_axis_iv_row_remains_in_readback
    seed_pre_edit_and_pointers(**FULL_KWARGS)
    seed_reply(WIRE_FULL, pov_success_body(RECORD_IEN))
    seed_post_readback(RECORD_IEN, **FULL_KWARGS, axis_iv_lister: [ AX4_ONE, AX4_TWO, "999" ])
    err = assert_raises(BH::SaveError) { BH.save_pov(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
  end

  def test_raises_when_readback_dot14_differs
    assert_post_call_readback_miss(**ONE_KWARGS, axis_v_readback: "99")
  end

  def test_raises_when_readback_1115_differs
    assert_post_call_readback_miss(**ONE_KWARGS, gaf_readback: "WRONG GAF TYPE")
  end

  def test_raises_outcome_unknown_when_cleared_axis_v_and_gaf_readback_is_empty_data
    clear_both = ONE_KWARGS.merge(axis_v: "", gaf: "")
    wire_clear_both = WIRE_ONE_DIAGNOSIS.sub("|#{AXIS_V}|#{PATIENT}|#{GAF_TEXT}", "||#{PATIENT}|")
    assert_post_call_readback_miss(**clear_both, wire: wire_clear_both, visit_axis_readback_empty: true)
  end

  def test_raises_outcome_unknown_when_cleared_gaf_row_missing_from_readback
    clear_both = ONE_KWARGS.merge(axis_v: "", gaf: "")
    wire_clear_both = WIRE_ONE_DIAGNOSIS.sub("|#{AXIS_V}|#{PATIENT}|#{GAF_TEXT}", "||#{PATIENT}|")
    assert_post_call_readback_miss(**clear_both, wire: wire_clear_both, visit_axis_readback_omit_1115: true)
  end

  def test_raises_outcome_unknown_when_cleared_axis_v_row_missing_from_readback
    clear_v = ONE_KWARGS.merge(axis_v: "", gaf: GAF_TEXT)
    wire_clear_v = WIRE_ONE_DIAGNOSIS.sub("|||#{AXIS_V}|", "||||")
    assert_post_call_readback_miss(**clear_v, wire: wire_clear_v, visit_axis_readback_omit_dot14: true)
  end

  def test_raises_outcome_unknown_when_cleared_gaf_row_missing_while_axis_v_set
    clear_gaf = ONE_KWARGS.merge(axis_v: AXIS_V, gaf: "")
    wire_clear_gaf = WIRE_ONE_DIAGNOSIS.sub("|#{PATIENT}|#{GAF_TEXT}", "|#{PATIENT}|")
    assert_post_call_readback_miss(**clear_gaf, wire: wire_clear_gaf, visit_axis_readback_omit_1115: true)
  end

  def test_raises_when_axis_iii_readback_differs_when_sent
    kwargs = ONE_KWARGS.merge(axis_iii: AXIS_III_TEXT)
    wire =
      "E|#{RECORD_IEN}|#{PROB_ONE}~~#{NARR_ONE}|#{AXIS_III_TEXT}||#{AXIS_V}|#{PATIENT}|#{GAF_TEXT}"
    assert_post_call_readback_miss(**kwargs, wire: wire, axis_iii_readback: "DIFFERENT AXIS III")
  end

  def test_succeeds_when_axis_iii_readback_is_arrayt_split_joined_to_sent_value
    sent = LONG_AXIS_III_SENT
    kwargs = ONE_KWARGS.merge(axis_iii: sent)
    wire = save_pov_wire_for(**kwargs)
    wp_lines = arrayt_wp_lines(sent)
    refute_equal [ sent ], wp_lines, "fixture must exercise ARRAYT line breaks"
    seed_success(wire, RECORD_IEN, **kwargs, axis_iii_wp_lines: wp_lines)
    assert_equal RECORD_IEN, BH.save_pov(**kwargs)
  end

  def test_raises_when_multi_line_axis_iii_readback_does_not_join_to_sent_value
    sent = LONG_AXIS_III_SENT
    kwargs = ONE_KWARGS.merge(axis_iii: sent)
    wire = save_pov_wire_for(**kwargs)
    wp_lines = arrayt_wp_lines(sent)
    wp_lines[-1] = "#{wp_lines.last}X"
    assert_post_call_readback_miss(**kwargs, wire: wire, axis_iii_wp_lines: wp_lines)
  end

  def test_amhg_frame_too_long_becomes_save_error_nothing_sent_not_outcome_unknown
    seed_pre_edit_and_pointers(**ONE_KWARGS)
    wrapper = FrameTooLongOnAmhgSavePov.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_pov(**ONE_KWARGS) }
    refute_match(/outcome unknown/i, err.message)
    assert_match(/nothing was sent|could not be framed|not sent/i, err.message)
    assert_kind_of RpmsRpc::Client::FrameTooLongError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_nil_context_amhg_frame_too_long_raises_nothing_sent_and_rebinds_ddr_context
    seed_pre_edit_and_pointers(**ONE_KWARGS)
    @mock.instance_variable_set(:@current_context, nil)
    wrapper = FrameTooLongOnAmhgSavePov.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_pov(**ONE_KWARGS) }
    refute_match(/outcome unknown/i, err.message)
    assert_match(/nothing was sent|could not be framed|not sent/i, err.message)
    assert_kind_of RpmsRpc::Client::FrameTooLongError, err.cause
    assert_equal [ "AMHGRPC", "CIAV VUECENTRIC" ], @mock.context_binds
    assert_equal "CIAV VUECENTRIC", @mock.current_context
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_nil_context_amhg_frame_too_long_restore_failure_does_not_replace_nothing_sent_error
    seed_pre_edit_and_pointers(**ONE_KWARGS)
    @mock.instance_variable_set(:@current_context, nil)
    @mock.unbindable_context!("CIAV VUECENTRIC")
    wrapper = FrameTooLongOnAmhgSavePov.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_pov(**ONE_KWARGS) }
    refute_match(/outcome unknown/i, err.message)
    assert_match(/nothing was sent|could not be framed|not sent/i, err.message)
    assert_kind_of RpmsRpc::Client::FrameTooLongError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_raises_when_post_call_readback_ddr_raises_rpms_error
    seed_pre_edit_and_pointers(**ONE_KWARGS)
    seed_reply(WIRE_ONE_DIAGNOSIS, pov_success_body(RECORD_IEN))
    seed_post_readback(RECORD_IEN, **ONE_KWARGS)
    wrapper = RaiseOnBhVisitReadbackForPov.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_pov(**ONE_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
    assert_kind_of RpmsRpc::Client::RpcMError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_amhg_rpc_timeout_becomes_save_error_with_ambiguous_outcome
    seed_pre_edit_and_pointers(**ONE_KWARGS)
    wrapper = TimeoutOnAmhgSavePov.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_pov(**ONE_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
    assert_kind_of RpmsRpc::Client::RpcTimeoutError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_error_message_does_not_echo_passed_narrative_or_patient
    secret = "UNIQUE_SYNTH_POV_MARKER_538"
    wire =
      "E|#{RECORD_IEN}|#{PROB_ONE}~~#{secret}|||#{AXIS_V}|#{PATIENT}|#{GAF_TEXT}"
    seed_pre_edit_and_pointers(**ONE_KWARGS.merge(diagnoses: [ { problem: PROB_ONE, narrative: secret } ]))
    seed_reply(wire, pov_success_body("0"))
    err = assert_raises(BH::SaveError) do
      BH.save_pov(**ONE_KWARGS.merge(diagnoses: [ { problem: PROB_ONE, narrative: secret } ]))
    end
    assert_amhg_reached
    refute_includes err.message, secret
    refute_includes err.message, PATIENT
  end

  # --- registration ---------------------------------------------------------

  def test_retry_safety_classifies_save_pov_as_non_idempotent_write
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(BH, :save_pov)
  end

  def test_required_rpcs_lists_amhg_save_pov_under_behavioral_health
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    assert_includes doc.fetch("modules").fetch("RpmsRpc::BehavioralHealth"), RPC
  end

  def test_mappings_ihs_defines_amhg_save_pov
    path = File.join(ROOT, "lib/rpms_rpc/mappings/ihs.rb")
    assert_includes File.read(path), "DataMapper.define(:amhg_save_pov)",
                    "production mapping :amhg_save_pov must ship with save_pov"
  end

  private

  def positions_of
    @mock.received_calls.each_with_index.select { |call, _| yield call }.map(&:last)
  end

  def save_call
    @mock.received_calls.find { |c| c[:rpc] == RPC }
  end

  def amhg_calls
    @mock.received_calls.select { |c| c[:rpc] == RPC }
  end

  def ddr_gets_calls
    @mock.received_calls.select { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
  end

  def pov_success_body(record_ien)
    "T00030Result#{RS}#{record_ien}#{RS}#{US}"
  end

  def seed_reply(wire_param, body)
    @mock.seed_text(:amhg_save_pov, wire_param, body)
  end

  def seed_success(wire_param, record_ien, pov_rows: nil, **kwargs)
    seed_pre_edit_and_pointers(**kwargs)
    seed_reply(wire_param, pov_success_body(record_ien))
    seed_post_readback(record_ien, pov_rows: pov_rows, **kwargs)
  end

  def seed_pre_edit_and_pointers(**kwargs)
    seed_pre_edit_patient(kwargs.fetch(:record_ien, RECORD_IEN), kwargs.fetch(:patient, PATIENT))
    kwargs.fetch(:diagnoses, []).each do |row|
      seed_pointer_exists(MHSS_PROBLEM_FILE, row.fetch(:problem))
    end
    kwargs.fetch(:axis_iv, []).each do |ax4|
      seed_pointer_exists(PSYCHOSOCIAL_FILE, ax4)
    end
  end

  def seed_pointer_exists(file, ien, blank_dot01: false, error: false, empty: false)
    key = Ddr.gets_entry_param(
      file: file, iens: "#{ien},", fields: PRE_POINTER_FIELDS, flags: PRE_POINTER_FLAGS
    ).to_s
    body =
      if error
        "[ERROR]"
      elsif empty
        "[Data]"
      else
        dot01 = blank_dot01 ? "" : "SYNTH,CODE"
        "[Data]\n#{file}^#{ien}^.01^#{dot01}^EXT"
      end
    @mock.seed(:ddr_gets_entry_data, key, body)
  end

  def seed_pre_edit_patient(ien, patient, signed: false, missing_1112: false, error: false, empty: false)
    key = Ddr.gets_entry_param(
      file: BH_VISIT_FILE, iens: "#{ien},",
      fields: PRE_EDIT_VISIT_FIELDS, flags: PRE_EDIT_VISIT_FLAGS
    ).to_s
    body =
      if error
        "[ERROR]"
      elsif empty
        "[Data]"
      else
        lines = [ "#{BH_VISIT_FILE}^#{ien}^.08^#{patient}^PATIENT,SYNTH" ]
        unless missing_1112
          signed_at = signed ? "3251031.12" : ""
          lines << "#{BH_VISIT_FILE}^#{ien}^1112^#{signed_at}^SIGNED"
        end
        "[Data]\n#{lines.join("\n")}"
      end
    @mock.seed(:ddr_gets_entry_data, key, body)
  end

  def pov_lister_key(record_ien)
    Ddr.lister_param(
      file: POV_FILE, xref: POV_XREF, part: record_ien.to_s,
      from: POV_FROM, screen: pov_lister_screen(record_ien),
      fields: POV_FIELDS, flags: POV_FLAGS, max: POV_MAX
    ).to_s
  end

  def pov_lister_screen(record_ien)
    "I $P(^(0),U,3)=#{record_ien}"
  end

  def axis_iv_lister_key(record_ien)
    Ddr.lister_param(
      file: AXIS_IV_FILE, iens: ",#{record_ien},",
      fields: AXIS_IV_FIELDS, flags: AXIS_IV_FLAGS, max: AXIS_IV_MAX
    ).to_s
  end

  def pov_rows_for(**kwargs)
    record = kwargs.fetch(:record_ien, RECORD_IEN).to_s
    kwargs.fetch(:diagnoses, []).map.with_index(1) do |row, idx|
      {
        ien: idx.to_s,
        problem: row.fetch(:problem).to_s,
        patient: kwargs.fetch(:patient, PATIENT).to_s,
        record: record,
        narrative_ext: row.fetch(:narrative).to_s
      }
    end
  end

  def replace_pov_rows
    pov_rows_for(**REPLACE_KWARGS)
  end

  def pov_lister_body(rows, more: false, error: false)
    return "[Errors]" if error

    lines = rows.map do |row|
      "#{row[:ien]}^#{row[:problem]}^#{row[:patient]}^#{row[:record]}^#{row[:narrative_ext]}"
    end
    body = "[Data]\n#{lines.join("\n")}"
    more ? "[Misc]\nMORE^1^1\n#{body}" : body
  end

  def pov_lister_body_v1(rows, more: false, error: false)
    return "[BEGIN_diERRORS]" if error

    lines = rows.map do |row|
      "#{row[:ien]}^#{row[:problem]}^#{row[:patient]}^#{row[:record]}^#{row[:narrative_ext]}"
    end
    data = "[BEGIN_diDATA]\n#{lines.join("\n")}\n[END_diDATA]"
    more ? "[Misc]\nMORE^1^1\n#{data}" : data
  end

  def axis_iv_lister_body(axis_iv_iens)
    lines = axis_iv_iens.each_with_index.map do |ien, idx|
      "#{idx + 1}^#{ien}"
    end
    "[Data]\n#{lines.join("\n")}"
  end

  def axis_iv_lister_body_v1(axis_iv_iens)
    lines = axis_iv_iens.each_with_index.map do |ien, idx|
      "#{idx + 1}^#{ien}"
    end
    "[BEGIN_diDATA]\n#{lines.join("\n")}\n[END_diDATA]"
  end

  def visit_axis_readback_body(record_ien, axis_v:, gaf:)
    [
      "#{BH_VISIT_FILE}^#{record_ien}^.14^#{axis_v}^EXT",
      "#{BH_VISIT_FILE}^#{record_ien}^1115^#{gaf}^EXT"
    ]
  end

  def axis_iii_wp_seed_body(record_ien, text, lines: nil)
    wp_text = lines ? lines.join("\n") : text
    "[Data]\n#{BH_VISIT_FILE}^#{record_ien}^#{AXIS_III_FIELD}^[WORD PROCESSING]\n#{wp_text}\n$$END$$"
  end

  def seed_post_readback(record_ien, pov_rows: nil, lister_more: false, lister_error: false,
                         axis_iv_lister: nil, axis_v_readback: nil, gaf_readback: nil,
                         axis_iii_readback: nil, axis_iii_wp_lines: nil,
                         pov_lister_reply: nil, axis_iv_lister_reply: nil,
                         visit_axis_readback_empty: false,
                         visit_axis_readback_omit_dot14: false, visit_axis_readback_omit_1115: false,
                         **kwargs)
    rows = pov_rows || pov_rows_for(**kwargs)
    pov_body = pov_lister_reply || pov_lister_body(rows, more: lister_more, error: lister_error)
    @mock.seed(:ddr_lister, pov_lister_key(record_ien), pov_body)

    ax4 = axis_iv_lister.nil? ? kwargs.fetch(:axis_iv, []) : axis_iv_lister
    ax4_body = axis_iv_lister_reply || axis_iv_lister_body(ax4)
    @mock.seed(:ddr_lister, axis_iv_lister_key(record_ien), ax4_body)

    axis_v = (axis_v_readback.nil? ? kwargs.fetch(:axis_v, "") : axis_v_readback).to_s
    gaf = (gaf_readback.nil? ? kwargs.fetch(:gaf, "") : gaf_readback).to_s
    axis_iii = axis_iii_readback.nil? ? kwargs[:axis_iii] : axis_iii_readback
    key = Ddr.gets_entry_param(
      file: BH_VISIT_FILE, iens: "#{record_ien},", fields: VISIT_AXIS_FIELDS, flags: VISIT_AXIS_FLAGS
    ).to_s
    visit_axis_body =
      if visit_axis_readback_empty
        "[Data]"
      else
        body_lines = visit_axis_readback_body(record_ien, axis_v: axis_v, gaf: gaf)
        body_lines = body_lines.each_with_index.filter_map do |line, idx|
          next if idx.zero? && visit_axis_readback_omit_dot14
          next if idx == 1 && visit_axis_readback_omit_1115

          line
        end
        "[Data]\n#{body_lines.join("\n")}"
      end
    @mock.seed(:ddr_gets_entry_data, key, visit_axis_body)

    if axis_iii && !axis_iii.to_s.empty?
      wp_key = Ddr.gets_entry_param(
        file: BH_VISIT_FILE, iens: "#{record_ien},", fields: AXIS_III_FIELD, flags: AXIS_III_FLAGS
      ).to_s
      wp_seed = axis_iii_readback.nil? ? axis_iii : axis_iii_readback
      wp_lines = axis_iii_wp_lines
      @mock.seed(:ddr_gets_entry_data, wp_key,
                 axis_iii_wp_seed_body(record_ien, wp_seed, lines: wp_lines))
    end
  end

  def pre_edit_ddr_param
    call = ddr_gets_calls.find do |c|
      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["IENS"] == "#{RECORD_IEN},"
    end
    flunk "expected pre-edit visit DDR GETS" unless call

    call[:params].first
  end

  def pointer_gets_index(file, ien)
    positions_of do |c|
      next false unless c[:rpc] == "DDR GETS ENTRY DATA"

      p = c[:params].first
      p["FILE"] == file && p["IENS"] == "#{ien},"
    end.first
  end

  def assert_pre_edit_ddr_call(iens)
    call = ddr_gets_calls.find do |c|
      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["IENS"] == iens && p["FIELDS"] == PRE_EDIT_VISIT_FIELDS
    end
    refute_nil call, "expected pre-edit visit DDR GETS for #{iens}"
  end

  def assert_pov_lister_ddr_call(record_ien)
    want = pov_lister_key(record_ien)
    call = @mock.received_calls.find { |c| c[:rpc] == "DDR LISTER" && c[:params].first.to_s == want }
    refute_nil call, "expected POV DDR LISTER on AD for record #{record_ien}"
  end

  def assert_pov_lister_ddr_after_second_call
    want = pov_lister_key(RECORD_IEN)
    lister_calls = @mock.received_calls.select { |c| c[:rpc] == "DDR LISTER" && c[:params].first.to_s == want }
    assert_operator lister_calls.size, :>=, 2, "expected post-call POV lister after each save"
    second_wire = amhg_calls.last[:params].first
    assert_equal WIRE_REPLACE, second_wire
    diag_piece = second_wire.split("|", -1)[2]
    assert_includes diag_piece, "#{PROB_REPLACE}~~#{NARR_REPLACE}",
                    "replace-all read-back must compare the second call's wire diagnoses"
    save_index = @mock.received_calls.rindex { |c| c[:rpc] == RPC }
    refute_nil save_index
    post_replace_lister = @mock.received_calls[(save_index + 1)..].find do |c|
      c[:rpc] == "DDR LISTER" && c[:params].first.to_s == want
    end
    refute_nil post_replace_lister, "expected POV DDR LISTER after the replace-all save"
  end

  # ARRAYT^AMHGU: after 65 bytes on a line, split on the next space and keep the space on the earlier line.
  def arrayt_wp_lines(text)
    lines = []
    line = +""
    text.each_char do |char|
      if char == " " && line.bytesize > 65
        line << char
        lines << line
        line = +""
      else
        line << char
      end
    end
    lines << line unless line.empty?
    lines
  end

  def assert_amhg_reached
    refute_empty amhg_calls, "expected #{RPC} before post-call SaveError"
  end

  def assert_pre_call_refusal(label: nil, **kwargs)
    err =
      if label
        assert_raises(BH::SaveError, label) { BH.save_pov(**kwargs) }
      else
        assert_raises(BH::SaveError) { BH.save_pov(**kwargs) }
      end
    assert_empty amhg_calls, "pre-call refusal must not RPC#{label ? " (#{label})" : ""}"
    err
  end

  def assert_input_validation_refusal(message_pattern = nil, **kwargs)
    err = assert_raises(BH::SaveError) { BH.save_pov(**kwargs) }
    assert_empty @mock.received_calls, "input validation must refuse before any RPC"
    assert_match(message_pattern, err.message) if message_pattern
    err
  end

  def assert_post_call_readback_miss(**kwargs)
    seed_opts = kwargs.dup
    wire = seed_opts.delete(:wire)
    pov_rows = seed_opts.delete(:pov_rows)
    lister_more = seed_opts.delete(:lister_more) || false
    lister_error = seed_opts.delete(:lister_error) || false
    axis_iv_lister = seed_opts.delete(:axis_iv_lister)
    axis_v_readback = seed_opts.delete(:axis_v_readback)
    gaf_readback = seed_opts.delete(:gaf_readback)
    axis_iii_readback = seed_opts.delete(:axis_iii_readback)
    axis_iii_wp_lines = seed_opts.delete(:axis_iii_wp_lines)
    pov_lister_reply = seed_opts.delete(:pov_lister_reply)
    axis_iv_lister_reply = seed_opts.delete(:axis_iv_lister_reply)
    visit_axis_readback_empty = seed_opts.delete(:visit_axis_readback_empty) || false
    visit_axis_readback_omit_dot14 = seed_opts.delete(:visit_axis_readback_omit_dot14) || false
    visit_axis_readback_omit_1115 = seed_opts.delete(:visit_axis_readback_omit_1115) || false
    record_ien = seed_opts.fetch(:record_ien, RECORD_IEN)
    wire_param = wire || wire_for(**seed_opts)
    seed_pre_edit_and_pointers(**seed_opts)
    seed_reply(wire_param, pov_success_body(record_ien))
    seed_post_readback(
      record_ien, pov_rows: pov_rows, lister_more: lister_more, lister_error: lister_error,
      axis_iv_lister: axis_iv_lister, axis_v_readback: axis_v_readback,
      gaf_readback: gaf_readback, axis_iii_readback: axis_iii_readback,
      axis_iii_wp_lines: axis_iii_wp_lines,
      pov_lister_reply: pov_lister_reply, axis_iv_lister_reply: axis_iv_lister_reply,
      visit_axis_readback_empty: visit_axis_readback_empty,
      visit_axis_readback_omit_dot14: visit_axis_readback_omit_dot14,
      visit_axis_readback_omit_1115: visit_axis_readback_omit_1115, **seed_opts
    )
    err = assert_raises(BH::SaveError) { BH.save_pov(**seed_opts) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: record_ien)
  end

  def wire_for(**kwargs)
    if kwargs[:diagnoses] == REPLACE_KWARGS[:diagnoses] &&
       kwargs[:axis_iv] == REPLACE_KWARGS[:axis_iv]
      WIRE_REPLACE
    elsif kwargs[:diagnoses] == FULL_KWARGS[:diagnoses]
      WIRE_FULL
    elsif kwargs[:axis_iii] && !kwargs[:axis_iii].to_s.empty?
      save_pov_wire_for(**kwargs)
    else
      WIRE_ONE_DIAGNOSIS
    end
  end

  def save_pov_wire_for(**kwargs)
    BH.send(:save_pov_wire, **kwargs)[0]
  end

  def assert_post_call_ambiguity(err, record_ien: nil)
    assert_match(/may have been changed|outcome unknown/i, err.message)
    refute_includes err.message, PATIENT
    refute_includes err.message, NARR_ONE
    return unless record_ien

    assert_includes err.message, record_ien
  end
end

class TimeoutOnAmhgSavePov < SimpleDelegator
  def call_rpc_global_array(rpc_name, *params)
    if rpc_name == "AMHG SAVE POV"
      super
      raise RpmsRpc::Client::RpcTimeoutError, "AMHG SAVE POV timed out (synthetic)"
    end

    super
  end
end

class ConnectionErrorOnAmhgSavePov < SimpleDelegator
  def call_rpc_global_array(rpc_name, *params)
    if rpc_name == "AMHG SAVE POV"
      super
      raise RpmsRpc::Client::ConnectionError, "AMHG SAVE POV connection lost (synthetic)"
    end

    super
  end
end

class RpcMErrorOnAmhgSavePov < SimpleDelegator
  def call_rpc_global_array(rpc_name, *params)
    if rpc_name == "AMHG SAVE POV"
      super
      raise RpmsRpc::Client::RpcMError, "AMHG SAVE POV M error (synthetic)"
    end

    super
  end
end

class RpcNotAvailableOnAmhgSavePov < SimpleDelegator
  def call_rpc_global_array(rpc_name, *_params)
    raise RpmsRpc::Client::RpcNotAvailableError, "AMHG SAVE POV not registered (synthetic)" if rpc_name == "AMHG SAVE POV"

    super
  end
end

class FrameTooLongOnAmhgSavePov < SimpleDelegator
  def call_rpc_global_array(rpc_name, *_params)
    raise RpmsRpc::Client::FrameTooLongError, "AMHG SAVE POV wire too long (synthetic)" if rpc_name == "AMHG SAVE POV"

    super
  end
end

class RaiseOnBhVisitReadbackForPov < SimpleDelegator
  BH_VISIT = "9002011"

  def initialize(inner)
    super
    @amhg_save_pov_seen = false
  end

  def call_rpc_global_array(rpc_name, *params)
    @amhg_save_pov_seen = true if rpc_name == "AMHG SAVE POV"
    super
  end

  def call_rpc(rpc_name, *params)
    if @amhg_save_pov_seen && rpc_name == "DDR GETS ENTRY DATA"
      file = params.first.is_a?(Hash) ? params.first["FILE"] : nil
      raise RpmsRpc::Client::RpcMError, "read-back failed (synthetic)" if file == BH_VISIT
    end

    super
  end
end
