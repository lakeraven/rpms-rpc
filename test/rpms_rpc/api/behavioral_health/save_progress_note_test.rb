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

# AMHG SAVE PROGRESS NOTES — PN^AMHGSVF (AMHGSVF.m:196-219), CCPD/PN/CMT^AMHGEVF.
# Shipped mapping :amhg_save_progress_notes → RPC "AMHG SAVE PROGRESS NOTES".
# Edit-only on the wire (piece 1 always E). Pre-edit #9002011 .08;1110;1112;
# post-call DDR 2101;.17;.18 and AMHG GET VISIT SOAP / COMM APP read-back.
class BehavioralHealthSaveProgressNoteTest < Minitest::Test
  BH = RpmsRpc::BehavioralHealth
  Ddr = RpmsRpc::DdrFileman
  RPC = "AMHG SAVE PROGRESS NOTES"
  RPC_SOAP = "AMHG GET VISIT SOAP"
  RPC_COMM = "AMHG GET VISIT COMM APP"
  RS = "\x1e" # $C(30)
  US = "\x1f" # $C(31)
  PLAIN_RPC_ERROR_MARKER = "SYNTH_PLAIN_RPC_ERROR_PN537"

  ROOT = File.expand_path("../../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  BH_VISIT_FILE = "9002011"
  PLACEMENT_FILE = "9002013.6"
  PRE_EDIT_FIELDS = ".08;1110;1112"
  PRE_EDIT_FLAGS = "I"
  READBACK_FIELDS = "2101;.17;.18"
  READBACK_FLAGS = "I"
  PLACEMENT_FIELDS = ".01;.02"
  PLACEMENT_FLAGS = "I"

  PATIENT = "990539"
  OTHER_PATIENT = "990540"
  RECORD_IEN = "8801"
  CHIEF_COMPLAINT = "SYN CC"
  REFERRED_TO = "SYN REF"
  PLACEMENT = "12"
  COMMENT = "SYNTH comment line"

  NOTE = "SYNTH progress note body for unit test."
  NOTE_MULTILINE = "Line one.\nSecond.\n\nFourth segment end."
  SOAP_ROWS_MULTILINE = [ "Line one.\n", "Second.\n", "\n", "Fourth segment end." ].freeze
  COMMENT_TWO_LINE = "First line.\nSecond line."
  COMM_ROWS_TWO_LINE = [ "First line.\n", "Second line." ].freeze

  WIRE_FULL =
    "E|#{RECORD_IEN}|#{CHIEF_COMPLAINT}|#{NOTE}|#{COMMENT}|#{PLACEMENT}|#{REFERRED_TO}|#{PATIENT}".freeze

  WIRE_BLANK_SCALARS =
    "E|#{RECORD_IEN}||#{NOTE_MULTILINE}|#{COMMENT}|||#{PATIENT}".freeze

  FULL_KWARGS = {
    record_ien: RECORD_IEN,
    patient: PATIENT,
    chief_complaint: CHIEF_COMPLAINT,
    note: NOTE,
    comment: COMMENT,
    placement_disposition: PLACEMENT,
    referred_to: REFERRED_TO
  }.freeze

  BLANK_SCALAR_KWARGS = FULL_KWARGS.merge(
    chief_complaint: "",
    note: NOTE_MULTILINE,
    placement_disposition: "",
    referred_to: ""
  ).freeze

  KWARG_KEYS = FULL_KWARGS.keys.freeze

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # --- wire (PN^AMHGSVF) ----------------------------------------------------

  def test_edit_pins_the_exact_eight_piece_wire_string
    seed_edit_success(WIRE_FULL, RECORD_IEN, **FULL_KWARGS)
    BH.save_progress_note(**FULL_KWARGS)

    call = save_call
    refute_nil call
    assert_equal RPC, call[:rpc]
    assert_equal 1, call[:params].length
    assert_equal WIRE_FULL, call[:params].first
    assert_equal 8, call[:params].first.split("|", -1).length
    assert_equal "E", call[:params].first.split("|", -1)[0]
  end

  def test_edit_pins_multiline_note_with_lf_and_blank_chief_complaint_placement_and_referred_to
    seed_edit_success(WIRE_BLANK_SCALARS, RECORD_IEN, **BLANK_SCALAR_KWARGS,
                      soap_rows: SOAP_ROWS_MULTILINE)
    BH.save_progress_note(**BLANK_SCALAR_KWARGS)

    assert_equal WIRE_BLANK_SCALARS, save_call[:params].first
    pieces = save_call[:params].first.split("|", -1)
    assert_equal "", pieces[2]
    assert_equal NOTE_MULTILINE, pieces[3]
    assert_equal "", pieces[5]
    assert_equal "", pieces[6]
    assert_equal NOTE_MULTILINE, SOAP_ROWS_MULTILINE.join("")
  end

  def test_save_progress_note_runs_under_amhgrpc_and_restores_the_callers_context
    seed_edit_success(WIRE_FULL, RECORD_IEN, **FULL_KWARGS)
    caller_context = @mock.current_context

    BH.save_progress_note(**FULL_KWARGS)

    assert_equal "AMHGRPC", save_call[:context]
    assert_equal caller_context, @mock.current_context
    assert_equal(
      [ "AMHGRPC", caller_context, "AMHGRPC", caller_context, "AMHGRPC", caller_context ],
      @mock.context_binds
    )
  end

  def test_save_progress_note_with_empty_comment_binds_amhgrpc_for_save_and_soap_then_restores_caller
    kwargs = FULL_KWARGS.merge(comment: "")
    wire = wire_for(**kwargs)
    seed_edit_success(wire, RECORD_IEN, **kwargs, skip_comm: true)
    caller_context = @mock.current_context

    BH.save_progress_note(**kwargs)

    assert_equal caller_context, @mock.current_context
    assert_equal [ "AMHGRPC", caller_context, "AMHGRPC", caller_context ], @mock.context_binds
  end

  def test_post_call_ddr_reads_do_not_run_under_amhgrpc_while_amhg_soap_and_comm_reads_do
    seed_edit_success(WIRE_FULL, RECORD_IEN, **FULL_KWARGS)
    @mock.instance_variable_set(:@current_context, nil)
    capture_io { BH.save_progress_note(**FULL_KWARGS) }

    save_index = @mock.received_calls.index { |c| c[:rpc] == RPC }
    refute_nil save_index
    after = @mock.received_calls[(save_index + 1)..]

    ddr_readback = after.find do |c|
      c[:rpc] == "DDR GETS ENTRY DATA" && c[:params].first["FIELDS"] == READBACK_FIELDS
    end
    soap = after.find { |c| c[:rpc] == RPC_SOAP }
    comm = after.find { |c| c[:rpc] == RPC_COMM }
    refute_nil ddr_readback
    refute_nil soap
    refute_nil comm

    after.each do |call|
      next unless call[:rpc].start_with?("DDR ")

      assert_equal "CIAV VUECENTRIC", call[:context],
                   "#{call[:rpc]} must run under the DDR context"
    end

    assert_equal "AMHGRPC", soap[:context]
    assert_equal "AMHGRPC", comm[:context]

    idx_ddr = positions_of do |c|
      c[:rpc] == "DDR GETS ENTRY DATA" && c[:params].first["FIELDS"] == READBACK_FIELDS
    end.first
    idx_soap = positions_of { |c| c[:rpc] == RPC_SOAP }.first
    idx_comm = positions_of { |c| c[:rpc] == RPC_COMM }.first
    refute_nil idx_ddr
    assert_operator idx_ddr, :<, idx_soap
    assert_operator idx_soap, :<, idx_comm
  end

  def test_nil_context_binds_exactly_amhgrpc_then_the_ddr_context
    seed_edit_success(WIRE_FULL, RECORD_IEN, **FULL_KWARGS)
    @mock.instance_variable_set(:@current_context, nil)
    capture_io { BH.save_progress_note(**FULL_KWARGS) }

    assert_equal(
      [
        "AMHGRPC", "CIAV VUECENTRIC",
        "AMHGRPC", "CIAV VUECENTRIC",
        "AMHGRPC", "CIAV VUECENTRIC"
      ],
      @mock.context_binds
    )
  end

  def test_edit_success_returns_the_requested_record_ien_after_readback
    seed_edit_success(WIRE_FULL, RECORD_IEN, **FULL_KWARGS)
    assert_equal RECORD_IEN, BH.save_progress_note(**FULL_KWARGS)
    assert_pre_edit_ddr_call("#{RECORD_IEN},")
    assert_readback_ddr_call("#{RECORD_IEN},")
  end

  def test_success_pins_pre_edit_visit_ddr_gets_fields_and_flags
    seed_edit_success(WIRE_FULL, RECORD_IEN, **FULL_KWARGS)
    BH.save_progress_note(**FULL_KWARGS)

    param = pre_edit_ddr_param
    assert_equal PRE_EDIT_FIELDS, param["FIELDS"]
    assert_equal PRE_EDIT_FLAGS, param["FLAGS"]
    assert_equal "#{RECORD_IEN},", param["IENS"]
  end

  def test_success_pins_post_call_ddr_gets_readback_fields_and_flags
    seed_edit_success(WIRE_FULL, RECORD_IEN, **FULL_KWARGS)
    BH.save_progress_note(**FULL_KWARGS)

    param = readback_ddr_param
    assert_equal READBACK_FIELDS, param["FIELDS"]
    assert_equal READBACK_FLAGS, param["FLAGS"]
  end

  def test_non_empty_placement_pins_pre_amhg_ddr_gets_on_file_9002013_6
    seed_edit_success(WIRE_FULL, RECORD_IEN, **FULL_KWARGS)
    BH.save_progress_note(**FULL_KWARGS)

    idx = positions_of do |c|
      next false unless c[:rpc] == "DDR GETS ENTRY DATA"

      p = c[:params].first
      p["FILE"] == PLACEMENT_FILE && p["IENS"] == "#{PLACEMENT}," &&
        p["FIELDS"] == PLACEMENT_FIELDS && p["FLAGS"] == PLACEMENT_FLAGS
    end.first
    refute_nil idx
    assert_operator idx, :<, positions_of { |c| c[:rpc] == RPC }.first
  end

  def test_pre_edit_ddr_and_placement_reads_run_before_amhg_save_and_not_under_amhgrpc
    seed_edit_success(WIRE_FULL, RECORD_IEN, **FULL_KWARGS)
    BH.save_progress_note(**FULL_KWARGS)

    amhg_idx = positions_of { |c| c[:rpc] == RPC }.first
    pre_edit_idx = positions_of do |c|
      next false unless c[:rpc] == "DDR GETS ENTRY DATA"

      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["FIELDS"] == PRE_EDIT_FIELDS
    end.first
    placement_idx = positions_of do |c|
      next false unless c[:rpc] == "DDR GETS ENTRY DATA"

      p = c[:params].first
      p["FILE"] == PLACEMENT_FILE && p["IENS"] == "#{PLACEMENT},"
    end.first

    refute_nil pre_edit_idx
    refute_nil placement_idx
    assert_operator pre_edit_idx, :<, amhg_idx
    assert_operator placement_idx, :<, amhg_idx

    [ pre_edit_idx, placement_idx ].each do |idx|
      refute_equal "AMHGRPC", @mock.received_calls[idx][:context]
    end
  end

  def test_empty_comment_does_not_call_amhg_get_visit_comm_app
    kwargs = FULL_KWARGS.merge(comment: "")
    wire = wire_for(**kwargs)
    seed_edit_success(wire, RECORD_IEN, **kwargs, skip_comm: true)
    BH.save_progress_note(**kwargs)

    refute @mock.received_calls.any? { |c| c[:rpc] == RPC_COMM }
  end

  def test_non_empty_comment_read_back_via_amhg_get_visit_comm_app
    seed_edit_success(WIRE_FULL, RECORD_IEN, **FULL_KWARGS)
    BH.save_progress_note(**FULL_KWARGS)

    call = @mock.received_calls.find { |c| c[:rpc] == RPC_COMM }
    refute_nil call
    assert_equal [ RECORD_IEN ], call[:params]
  end

  def test_accepts_lf_in_note_and_comment_on_the_wire
    kwargs = FULL_KWARGS.merge(note: "line one\nline two", comment: "appt\nsoon")
    wire = wire_for(**kwargs)
    seed_edit_success(wire, RECORD_IEN, **kwargs)
    BH.save_progress_note(**kwargs)

    assert_equal wire, save_call[:params].first
  end

  def test_soap_readback_confirms_when_joined_raw_rows_match_note_with_lf_preserved
    seed_edit_success(WIRE_BLANK_SCALARS, RECORD_IEN, **BLANK_SCALAR_KWARGS,
                      soap_rows: SOAP_ROWS_MULTILINE)
    assert_equal RECORD_IEN, BH.save_progress_note(**BLANK_SCALAR_KWARGS)
  end

  def test_soap_readback_not_confirmed_when_stored_rows_strip_lf
    stripped = SOAP_ROWS_MULTILINE.map { |row| row.delete("\n") }
    seed_pre_edit_success(**BLANK_SCALAR_KWARGS)
    seed_success(WIRE_BLANK_SCALARS, RECORD_IEN)
    seed_readback("#{RECORD_IEN},", **BLANK_SCALAR_KWARGS)
    seed_soap(RECORD_IEN, NOTE_MULTILINE, rows: stripped)
    seed_comm(RECORD_IEN, COMMENT)
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**BLANK_SCALAR_KWARGS) }
    assert_not_confirmed(err, record_ien: RECORD_IEN)
  end

  # --- registration ---------------------------------------------------------

  def test_retry_safety_classifies_save_progress_note_as_non_idempotent_write
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(BH, :save_progress_note)
  end

  def test_required_rpcs_lists_amhg_save_progress_notes_under_behavioral_health
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    list = doc.fetch("modules").fetch("RpmsRpc::BehavioralHealth")
    assert_includes list, RPC
    assert_includes list, RPC_SOAP
    assert_includes list, RPC_COMM
  end

  def test_save_error_is_a_subclass_of_rpms_rpc_error
    assert_operator BH::SaveError, :<, RpmsRpc::Error
  end

  # --- pre-call refusals (no RPC) -------------------------------------------

  def test_refuses_nil_for_any_keyword_without_rpc
    KWARG_KEYS.each do |key|
      assert_pre_call_refusal(**FULL_KWARGS.merge(key => nil), label: key)
    end
  end

  def test_refuses_blank_record_ien_without_rpc
    assert_pre_call_refusal(**FULL_KWARGS.merge(record_ien: ""))
    assert_pre_call_refusal(**FULL_KWARGS.merge(record_ien: "   "))
  end

  def test_refuses_non_positive_integer_record_ien_or_patient_without_rpc
    %w[0 -1 abc].each do |bad|
      assert_pre_call_refusal(**FULL_KWARGS.merge(record_ien: bad))
      assert_pre_call_refusal(**FULL_KWARGS.merge(patient: bad))
    end
  end

  def test_refuses_note_that_is_blank_after_strip_without_rpc
    assert_pre_call_refusal(**FULL_KWARGS.merge(note: ""))
    assert_pre_call_refusal(**FULL_KWARGS.merge(note: "   "))
    assert_pre_call_refusal(**FULL_KWARGS.merge(note: "\n\n"))
  end

  def test_refuses_comment_that_is_non_empty_but_blank_after_strip_without_rpc
    assert_pre_call_refusal(**FULL_KWARGS.merge(comment: "   "))
    assert_pre_call_refusal(**FULL_KWARGS.merge(comment: "\t"))
  end

  def test_allows_empty_comment_on_the_wire
    wire = WIRE_FULL.sub("|#{COMMENT}|", "||")
    kwargs = FULL_KWARGS.merge(comment: "")
    seed_edit_success(wire, RECORD_IEN, **kwargs, skip_comm: true)
    BH.save_progress_note(**kwargs)

    assert_equal wire, save_call[:params].first
  end

  def test_refuses_chief_complaint_outside_two_to_eighty_bytes_when_non_empty_without_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_placement(PLACEMENT)
    assert_pre_call_refusal(**FULL_KWARGS.merge(chief_complaint: "A"))
    assert_pre_call_refusal(**FULL_KWARGS.merge(chief_complaint: "X" * 81))
    assert_pre_call_refusal(**FULL_KWARGS.merge(chief_complaint: "#{'a' * 79}é"))
  end

  def test_refuses_referred_to_outside_two_to_thirty_bytes_when_non_empty_without_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_placement(PLACEMENT)
    assert_pre_call_refusal(**FULL_KWARGS.merge(referred_to: "A"))
    assert_pre_call_refusal(**FULL_KWARGS.merge(referred_to: "X" * 31))
  end

  def test_refuses_non_empty_placement_disposition_that_is_not_a_positive_integer_without_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    %w[0 -1 abc].each do |bad|
      assert_pre_call_refusal(**FULL_KWARGS.merge(placement_disposition: bad))
    end
  end

  def test_refuses_at_sign_only_chief_complaint_or_referred_to_after_strip_without_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_placement(PLACEMENT)
    assert_pre_call_refusal(**FULL_KWARGS.merge(chief_complaint: "@"))
    assert_pre_call_refusal(**FULL_KWARGS.merge(referred_to: " @ "))
  end

  def test_refuses_pipe_or_caret_in_any_value_without_rpc
    KWARG_KEYS.each do |key|
      assert_pre_call_refusal(**FULL_KWARGS.merge(key => "a|b"), label: "pipe #{key}")
      assert_pre_call_refusal(**FULL_KWARGS.merge(key => "a^b"), label: "caret #{key}")
    end
  end

  def test_refuses_control_characters_outside_note_and_comment_without_rpc
    toxic = [ RS, US, "\x01", "\x7f", "\r", "\n" ]
    toxic.each do |bad|
      assert_pre_call_refusal(**FULL_KWARGS.merge(chief_complaint: bad))
    end
  end

  def test_refuses_cr_in_note_or_comment_without_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_placement(PLACEMENT)
    assert_pre_call_refusal(**FULL_KWARGS.merge(note: "a\rb"))
    assert_pre_call_refusal(**FULL_KWARGS.merge(comment: "a\rb"))
  end

  def test_invalid_utf8_bytes_raise_save_error_not_argument_error_without_rpc
    invalid = String.new("\xC0\x80", encoding: Encoding::ASCII_8BIT)
    assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS.merge(note: invalid)) }
    assert_empty amhg_calls
  end

  def test_utf16_encoded_strings_raise_save_error_without_rpc
    encoded = "SYNTH".encode("UTF-16LE")
    assert_pre_call_refusal(**FULL_KWARGS.merge(chief_complaint: encoded))
  end

  def test_refuses_replacement_character_in_any_text_value_without_rpc
    toxic = "SYNTH \uFFFD text"
    %i[chief_complaint note comment referred_to].each do |key|
      @mock = RpmsRpc.mock!
      kwargs = FULL_KWARGS.merge(key => toxic)
      wire = wire_for(**kwargs)
      seed_edit_success(wire, RECORD_IEN, **kwargs)
      assert_raises(BH::SaveError) { BH.save_progress_note(**kwargs) }
      assert_empty @mock.received_calls
    end
  end

  def test_rejects_unknown_keyword_without_rpc
    err = assert_raises(ArgumentError) { BH.save_progress_note(**FULL_KWARGS, esign: true) }
    refute_empty err.message
    assert_empty @mock.received_calls
  end

  def test_pre_edit_refuses_when_visit_read_errors_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT, error: true)
    assert_pre_call_refusal(**FULL_KWARGS, label: "pre-edit error")
  end

  def test_pre_edit_refuses_when_visit_read_is_empty_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT, empty: true)
    assert_pre_call_refusal(**FULL_KWARGS, label: "pre-edit empty")
  end

  def test_pre_edit_refuses_when_unseeded_visit_read_is_nil_without_amhg_rpc
    assert_pre_call_refusal(**FULL_KWARGS, label: "pre-edit nil")
  end

  def test_pre_edit_refuses_when_stored_patient_differs_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, OTHER_PATIENT)
    assert_pre_call_refusal(**FULL_KWARGS, label: "patient mismatch")
  end

  def test_pre_edit_refuses_when_visit_is_signed_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT, signed: true)
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_match(/signed/i, err.message)
    assert_empty amhg_calls
  end

  def test_pre_edit_refuses_when_1112_row_is_missing_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT, missing_1112: true)
    assert_pre_call_refusal(**FULL_KWARGS, label: "missing 1112")
  end

  def test_pre_edit_refuses_when_ehr_flag_is_set_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT, ehr: true)
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_match(/ehr/i, err.message)
    assert_empty amhg_calls
  end

  def test_pre_edit_refuses_when_1110_row_is_missing_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT, missing_1110: true)
    assert_pre_call_refusal(**FULL_KWARGS, label: "missing 1110")
  end

  def test_pre_edit_refuses_inactive_placement_disposition_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_placement(PLACEMENT, inactive: true)
    assert_pre_call_refusal(**FULL_KWARGS, label: "inactive placement")
  end

  def test_pre_edit_refuses_missing_placement_entry_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    assert_pre_call_refusal(**FULL_KWARGS, label: "missing placement")
  end

  def test_refuses_placement_with_blank_dot01_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_placement(PLACEMENT, missing_dot01: true)
    assert_pre_call_refusal(**FULL_KWARGS, label: "placement blank .01")
  end

  # --- post-call failures ---------------------------------------------------

  def test_raises_when_reply_has_m_error_row
    seed_post_amhg_trap(WIRE_FULL, **FULL_KWARGS) { seed_reply(WIRE_FULL, "M ERROR|synthetic trap#{RS}") }
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
  end

  def test_raises_when_reply_has_zero_tilde_error_row
    seed_post_amhg_trap(WIRE_FULL, **FULL_KWARGS) do
      seed_reply(WIRE_FULL, "T00030Result#{RS}0~Update Chief Complaint#{RS}#{US}")
    end
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
  end

  def test_raises_when_reply_ien_is_zero_or_missing
    seed_post_amhg_trap(WIRE_FULL, **FULL_KWARGS) { seed_success(WIRE_FULL, "0") }
    assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    seed_post_amhg_trap(WIRE_FULL, **FULL_KWARGS) { seed_reply(WIRE_FULL, "T00030Result#{RS}#{RS}#{US}") }
    assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
  end

  def test_raises_when_returned_ien_differs_from_requested
    seed_pre_edit_success(**FULL_KWARGS)
    seed_success(WIRE_FULL, "9999")
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
  end

  def test_raises_when_readback_ddr_mismatches_chief_complaint
    seed_pre_edit_success(**FULL_KWARGS)
    seed_success(WIRE_FULL, RECORD_IEN)
    seed_readback("#{RECORD_IEN},", **FULL_KWARGS, overrides: { "2101" => "OTHER" })
    seed_soap(RECORD_IEN, NOTE)
    seed_comm(RECORD_IEN, COMMENT)
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_not_confirmed(err, record_ien: RECORD_IEN)
  end

  def test_raises_when_soap_readback_does_not_match_note
    seed_pre_edit_success(**FULL_KWARGS)
    seed_success(WIRE_FULL, RECORD_IEN)
    seed_readback("#{RECORD_IEN},", **FULL_KWARGS)
    seed_soap(RECORD_IEN, "wrong note")
    seed_comm(RECORD_IEN, COMMENT)
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_not_confirmed(err, record_ien: RECORD_IEN)
  end

  def test_raises_when_comm_app_readback_does_not_match_comment
    seed_pre_edit_success(**FULL_KWARGS)
    seed_success(WIRE_FULL, RECORD_IEN)
    seed_readback("#{RECORD_IEN},", **FULL_KWARGS)
    seed_soap(RECORD_IEN, NOTE)
    seed_comm(RECORD_IEN, "wrong comment")
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_not_confirmed(err, record_ien: RECORD_IEN)
  end

  def test_raises_when_soap_readback_is_m_error_or_has_no_data_rows
    seed_pre_edit_success(**FULL_KWARGS)
    seed_success(WIRE_FULL, RECORD_IEN)
    seed_readback("#{RECORD_IEN},", **FULL_KWARGS)
    seed_comm(RECORD_IEN, COMMENT)

    seed_soap(RECORD_IEN, NOTE, rows: [ "M ERROR|synthetic trap" ])
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_not_confirmed(err, record_ien: RECORD_IEN)

    @mock.seed_text(:amhg_visit_soap, RECORD_IEN, "T00250Soap#{RS}#{US}")
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_not_confirmed(err, record_ien: RECORD_IEN)
  end

  def test_amhg_rpc_timeout_becomes_save_error_with_ambiguous_outcome
    seed_pre_edit_success(**FULL_KWARGS)
    wrapper = TimeoutOnAmhgSaveProgressNotes.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_kind_of RpmsRpc::Client::RpcTimeoutError, err.cause
    assert_match(/may have been filed/i, err.message)
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_amhg_connection_error_becomes_save_error_with_ambiguous_outcome
    seed_pre_edit_success(**FULL_KWARGS)
    wrapper = ConnectionErrorOnAmhgSaveProgressNotes.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_kind_of RpmsRpc::Client::ConnectionError, err.cause
    assert_match(/may have been filed/i, err.message)
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_amhg_rpc_m_error_becomes_save_error_with_ambiguous_outcome
    seed_pre_edit_success(**FULL_KWARGS)
    wrapper = RpcMErrorOnAmhgSaveProgressNotes.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
    assert_kind_of RpmsRpc::Client::RpcMError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_amhg_plain_rpc_error_becomes_save_error_with_ambiguous_outcome
    seed_pre_edit_success(**FULL_KWARGS)
    wrapper = RpcErrorOnAmhgSaveProgressNotes.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
    assert_kind_of RpmsRpc::Client::RpcError, err.cause
    refute_kind_of RpmsRpc::Client::RpcMError, err.cause
    refute_includes err.message, PLAIN_RPC_ERROR_MARKER
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_amhg_rpc_not_available_error_is_not_wrapped
    seed_pre_edit_success(**FULL_KWARGS)
    wrapper = RpcNotAvailableOnAmhgSaveProgressNotes.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    assert_raises(RpmsRpc::Client::RpcNotAvailableError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_empty amhg_calls
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_amhg_rpc_refused_error_is_not_wrapped
    seed_pre_edit_success(**FULL_KWARGS)
    wrapper = RpcRefusedOnAmhgSaveProgressNotes.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    assert_raises(RpmsRpc::Client::RpcRefusedError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_empty amhg_calls
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_post_call_amhg_get_visit_soap_rpc_refused_error_becomes_ambiguous_save_error
    seed_after_save_reply(**FULL_KWARGS)
    wrapper = RaiseOnAmhgRpcAfterSaveProgressNotes.new(
      @mock, rpc: RPC_SOAP, error: RpmsRpc::Client::RpcRefusedError.new("AMHG GET VISIT SOAP refused (synthetic)")
    )
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
    assert_kind_of RpmsRpc::Client::RpcRefusedError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_post_call_amhg_get_visit_soap_rpc_not_available_error_becomes_ambiguous_save_error
    seed_after_save_reply(**FULL_KWARGS)
    wrapper = RaiseOnAmhgRpcAfterSaveProgressNotes.new(
      @mock,
      rpc: RPC_SOAP,
      error: RpmsRpc::Client::RpcNotAvailableError.new("AMHG GET VISIT SOAP not registered (synthetic)")
    )
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
    assert_kind_of RpmsRpc::Client::RpcNotAvailableError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_post_call_amhg_get_visit_soap_rpc_error_becomes_ambiguous_save_error
    seed_after_save_reply(**FULL_KWARGS)
    wrapper = RaiseOnAmhgRpcAfterSaveProgressNotes.new(
      @mock, rpc: RPC_SOAP, error: RpmsRpc::Client::RpcError.new("AMHG GET VISIT SOAP failed (synthetic)")
    )
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
    assert_kind_of RpmsRpc::Client::RpcError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_post_call_amhg_get_visit_comm_app_rpc_refused_error_becomes_ambiguous_save_error
    seed_after_save_reply(**FULL_KWARGS)
    seed_soap(RECORD_IEN, NOTE)
    wrapper = RaiseOnAmhgRpcAfterSaveProgressNotes.new(
      @mock,
      rpc: RPC_COMM,
      error: RpmsRpc::Client::RpcRefusedError.new("AMHG GET VISIT COMM APP refused (synthetic)")
    )
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
    assert_kind_of RpmsRpc::Client::RpcRefusedError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_post_call_ddr_scalar_readback_error_becomes_ambiguous_save_error
    seed_after_save_reply(**FULL_KWARGS)
    wrapper = RaiseOnProgressNoteDdrScalarReadback.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
    assert_kind_of RpmsRpc::Error, err.cause
    refute_kind_of RpmsRpc::Client::RpcError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_bmx_call_rpc_only_client_confirms_multiline_note_and_two_line_comment_when_rows_keep_trailing_lf
    kwargs = BLANK_SCALAR_KWARGS.merge(comment: COMMENT_TWO_LINE)
    wire = wire_for(**kwargs)
    soap_reply = RpmsRpc::Reply.from_wire([ "T00250Soap", *SOAP_ROWS_MULTILINE ])
    comm_reply = RpmsRpc::Reply.from_wire([ "T00250CommentAppointment", *COMM_ROWS_TWO_LINE ])
    seed_pre_edit_success(**kwargs)
    seed_success(wire, RECORD_IEN)
    seed_readback("#{RECORD_IEN},", **kwargs)
    wrapper = CallRpcWithoutGlobalArray.new(@mock, soap_reply: soap_reply, comm_reply: comm_reply)
    refute wrapper.respond_to?(:call_rpc_global_array)
    RpmsRpc.configure { |c| c.client = wrapper }
    assert_equal RECORD_IEN, BH.save_progress_note(**kwargs)
    assert_amhg_reached
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_bmx_call_rpc_only_client_not_confirmed_when_pre_split_rows_strip_trailing_lf
    kwargs = BLANK_SCALAR_KWARGS.merge(comment: COMMENT_TWO_LINE)
    wire = wire_for(**kwargs)
    stripped_soap = SOAP_ROWS_MULTILINE.map { |row| row.delete("\n") }
    stripped_comm = COMM_ROWS_TWO_LINE.map { |row| row.delete("\n") }
    soap_reply = RpmsRpc::Reply.from_wire([ "T00250Soap", *stripped_soap ])
    comm_reply = RpmsRpc::Reply.from_wire([ "T00250CommentAppointment", *stripped_comm ])
    seed_pre_edit_success(**kwargs)
    seed_success(wire, RECORD_IEN)
    seed_readback("#{RECORD_IEN},", **kwargs)
    wrapper = CallRpcWithoutGlobalArray.new(@mock, soap_reply: soap_reply, comm_reply: comm_reply)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**kwargs) }
    assert_amhg_reached
    assert_not_confirmed(err, record_ien: RECORD_IEN)
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_error_message_does_not_echo_passed_values
    secret = "UNIQUE_SYNTH_MARKER_539"
    seed_post_amhg_trap(WIRE_FULL, **FULL_KWARGS.merge(note: secret)) { seed_success(WIRE_FULL.sub(NOTE, secret), "0") }
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**FULL_KWARGS.merge(note: secret)) }
    refute_includes err.message, secret
    refute_includes err.message, PATIENT
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

  def pre_edit_ddr_param
    call = ddr_gets_calls.find do |c|
      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["FIELDS"] == PRE_EDIT_FIELDS
    end
    flunk "expected pre-edit DDR GETS" unless call

    call[:params].first
  end

  def readback_ddr_param
    call = ddr_gets_calls.reverse.find do |c|
      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["FIELDS"] == READBACK_FIELDS
    end
    flunk "expected read-back DDR GETS" unless call

    call[:params].first
  end

  def success_body(ien)
    "T00030Result#{RS}#{ien}#{RS}#{US}"
  end

  def seed_reply(wire, body)
    @mock.seed_text(:amhg_save_progress_notes, wire, body)
  end

  def seed_success(wire, ien)
    seed_reply(wire, success_body(ien))
  end

  def ddr_gets_key(file:, iens:, fields:, flags:)
    Ddr.gets_entry_param(file: file, iens: iens, fields: fields, flags: flags).to_s
  end

  def readback_values_for(**kwargs)
    {
      "2101" => kwargs.fetch(:chief_complaint).to_s,
      ".17" => kwargs.fetch(:placement_disposition).to_s,
      ".18" => kwargs.fetch(:referred_to).to_s
    }
  end

  def seed_pre_edit_patient(ien, patient, error: false, empty: false, signed: false,
                            missing_1112: false, missing_1110: false, ehr: false)
    key = ddr_gets_key(
      file: BH_VISIT_FILE, iens: "#{ien},", fields: PRE_EDIT_FIELDS, flags: PRE_EDIT_FLAGS
    )
    body =
      if error
        "[ERROR]"
      elsif empty
        "[Data]"
      else
        lines = [ "#{BH_VISIT_FILE}^#{ien}^.08^#{patient}^PATIENT,SYNTH" ]
        lines << "#{BH_VISIT_FILE}^#{ien}^1110^#{'1' if ehr}^EHR" unless missing_1110
        unless missing_1112
          signed_at = signed ? "3251031.12" : ""
          lines << "#{BH_VISIT_FILE}^#{ien}^1112^#{signed_at}^SIGNED"
        end
        "[Data]\n#{lines.join("\n")}"
      end
    @mock.seed(:ddr_gets_entry_data, key, body)
  end

  def seed_placement(ien, inactive: false, missing_dot01: false)
    key = ddr_gets_key(
      file: PLACEMENT_FILE, iens: "#{ien},", fields: PLACEMENT_FIELDS, flags: PLACEMENT_FLAGS
    )
    dot01 = missing_dot01 ? "" : "SYNTH PLACEMENT"
    dot02 = inactive ? "1" : ""
    body = "[Data]\n#{PLACEMENT_FILE}^#{ien}^.01^#{dot01}^EXT\n#{PLACEMENT_FILE}^#{ien}^.02^#{dot02}^EXT"
    @mock.seed(:ddr_gets_entry_data, key, body)
  end

  def seed_readback(iens, **kwargs)
    overrides = kwargs.delete(:overrides) || {}
    values = readback_values_for(**kwargs).merge(overrides)
    ien_bare = iens.delete_suffix(",")
    lines = values.map { |field, internal| "#{BH_VISIT_FILE}^#{ien_bare}^#{field}^#{internal}^EXT" }
    key = ddr_gets_key(
      file: BH_VISIT_FILE, iens: iens, fields: READBACK_FIELDS, flags: READBACK_FLAGS
    )
    @mock.seed(:ddr_gets_entry_data, key, "[Data]\n#{lines.join("\n")}")
  end

  def soap_body(rows)
    "T00250Soap#{RS}#{Array(rows).join(RS)}#{RS}#{US}"
  end

  def comm_body(text)
    "T00250CommentAppointment#{RS}#{text}#{RS}#{US}"
  end

  def seed_soap(ien, note, rows: nil)
    lines = rows || [ note ]
    @mock.seed_text(:amhg_visit_soap, ien, soap_body(lines))
  end

  def seed_comm(ien, comment)
    @mock.seed_text(:amhg_visit_comment_appointment, ien, comm_body(comment))
  end

  def seed_pre_edit_success(**kwargs)
    seed_pre_edit_patient(kwargs.fetch(:record_ien), kwargs.fetch(:patient))
    placement = kwargs.fetch(:placement_disposition).to_s
    seed_placement(placement) unless placement.empty?
  end

  def seed_edit_success(wire, ien, skip_comm: false, soap_rows: nil, **kwargs)
    seed_pre_edit_success(**kwargs)
    seed_success(wire, ien)
    seed_readback("#{ien},", **kwargs)
    seed_soap(ien, kwargs.fetch(:note), rows: soap_rows)
    seed_comm(ien, kwargs.fetch(:comment)) unless skip_comm || kwargs.fetch(:comment).to_s.empty?
  end

  def seed_after_save_reply(**kwargs)
    wire = wire_for(**kwargs)
    ien = kwargs.fetch(:record_ien)
    seed_pre_edit_success(**kwargs)
    seed_success(wire, ien)
    seed_readback("#{ien},", **kwargs)
  end

  def seed_post_amhg_trap(_wire, **kwargs)
    seed_pre_edit_success(**kwargs)
    yield
  end

  def assert_pre_edit_ddr_call(iens)
    call = ddr_gets_calls.find do |c|
      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["IENS"] == iens && p["FIELDS"] == PRE_EDIT_FIELDS
    end
    refute_nil call
  end

  def assert_readback_ddr_call(iens)
    call = ddr_gets_calls.find do |c|
      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["IENS"] == iens && p["FIELDS"] == READBACK_FIELDS
    end
    refute_nil call
  end

  def assert_amhg_reached
    refute_empty amhg_calls
  end

  def assert_pre_call_refusal(label: nil, **kwargs)
    err = assert_raises(BH::SaveError) { BH.save_progress_note(**kwargs) }
    label_text = label.nil? ? "" : " (#{label})"
    assert_empty amhg_calls, "pre-call refusal must not RPC#{label_text}"
    err
  end

  def wire_for(**kwargs)
    cc = kwargs.fetch(:chief_complaint).to_s
    note = kwargs.fetch(:note).to_s
    comment = kwargs.fetch(:comment).to_s
    placement = kwargs.fetch(:placement_disposition).to_s
    referred = kwargs.fetch(:referred_to).to_s
    patient = kwargs.fetch(:patient).to_s
    ien = kwargs.fetch(:record_ien).to_s
    "E|#{ien}|#{cc}|#{note}|#{comment}|#{placement}|#{referred}|#{patient}"
  end

  def assert_post_call_ambiguity(err, record_ien:)
    assert_match(/AMHG SAVE PROGRESS NOTES outcome unknown/i, err.message)
    assert_match(/may have been filed/i, err.message)
    assert_includes err.message, record_ien
    refute_includes err.message, PATIENT
    refute_includes err.message, NOTE
  end

  def assert_not_confirmed(err, record_ien:)
    assert_match(/not confirmed|may have been filed/i, err.message)
    assert_includes err.message, record_ien
  end
end

class TimeoutOnAmhgSaveProgressNotes < SimpleDelegator
  def call_rpc_global_array(rpc_name, *params)
    if rpc_name == "AMHG SAVE PROGRESS NOTES"
      super
      raise RpmsRpc::Client::RpcTimeoutError, "AMHG SAVE PROGRESS NOTES timed out (synthetic)"
    end

    super
  end
end

class ConnectionErrorOnAmhgSaveProgressNotes < SimpleDelegator
  def call_rpc_global_array(rpc_name, *params)
    if rpc_name == "AMHG SAVE PROGRESS NOTES"
      super
      raise RpmsRpc::Client::ConnectionError, "AMHG SAVE PROGRESS NOTES connection lost (synthetic)"
    end

    super
  end
end

class RpcMErrorOnAmhgSaveProgressNotes < SimpleDelegator
  def call_rpc_global_array(rpc_name, *params)
    if rpc_name == "AMHG SAVE PROGRESS NOTES"
      super
      raise RpmsRpc::Client::RpcMError, "AMHG SAVE PROGRESS NOTES M error (synthetic)"
    end

    super
  end
end

class RpcErrorOnAmhgSaveProgressNotes < SimpleDelegator
  def call_rpc_global_array(rpc_name, *params)
    if rpc_name == BehavioralHealthSaveProgressNoteTest::RPC
      super
      raise RpmsRpc::Client::RpcError, BehavioralHealthSaveProgressNoteTest::PLAIN_RPC_ERROR_MARKER
    end

    super
  end
end

class RpcNotAvailableOnAmhgSaveProgressNotes < SimpleDelegator
  def call_rpc_global_array(rpc_name, *_params)
    if rpc_name == BehavioralHealthSaveProgressNoteTest::RPC
      raise RpmsRpc::Client::RpcNotAvailableError, "AMHG SAVE PROGRESS NOTES not registered (synthetic)"
    end

    super
  end
end

class RpcRefusedOnAmhgSaveProgressNotes < SimpleDelegator
  def call_rpc_global_array(rpc_name, *_params)
    if rpc_name == BehavioralHealthSaveProgressNoteTest::RPC
      raise RpmsRpc::Client::RpcRefusedError, "AMHG SAVE PROGRESS NOTES refused (synthetic)"
    end

    super
  end
end

class RaiseOnAmhgRpcAfterSaveProgressNotes < SimpleDelegator
  def initialize(inner, rpc:, error:)
    super(inner)
    @rpc = rpc
    @error = error
  end

  def call_rpc_global_array(rpc_name, *params)
    raise @error if rpc_name == @rpc

    super
  end
end

class RaiseOnProgressNoteDdrScalarReadback < SimpleDelegator
  READBACK_FIELDS = "2101;.17;.18"

  def call_rpc(rpc_name, *params)
    if rpc_name == "DDR GETS ENTRY DATA" && params.first.is_a?(Hash) &&
       params.first["FIELDS"] == READBACK_FIELDS
      raise RpmsRpc::Error, "progress note scalar read-back failed (synthetic)"
    end

    super
  end
end

# BMX #call_rpc returns Reply.from_wire(split_bmx_reply(...)): rows are already
# split on $C(30) with trailing LF preserved; Wire falls back to #call_rpc when
# #call_rpc_global_array is absent.
class CallRpcWithoutGlobalArray < SimpleDelegator
  def initialize(inner, soap_reply:, comm_reply:)
    super(inner)
    @soap_reply = soap_reply
    @comm_reply = comm_reply
  end

  def respond_to?(meth, include_all = false)
    return false if meth == :call_rpc_global_array

    super
  end

  def call_rpc(rpc_name, *params)
    return @soap_reply if rpc_name == "AMHG GET VISIT SOAP"
    return @comm_reply if rpc_name == "AMHG GET VISIT COMM APP"

    super
  end
end
