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

# AMHG SAVE HEALTH FACTORS — HF^AMHGSVF (AMHGSVF.m:277-305), MODHF/DELHF^AMHGEVF.
class BehavioralHealthSaveHealthFactorsTest < Minitest::Test
  BH = RpmsRpc::BehavioralHealth
  Ddr = RpmsRpc::DdrFileman
  RPC = "AMHG SAVE HEALTH FACTORS"
  RS = "\x1e"
  US = "\x1f"

  ROOT = File.expand_path("../../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")
  RPCS_MD_PATH = File.join(ROOT, "docs/rpcs.md")
  MAPPINGS_PATH = File.join(ROOT, "lib/rpms_rpc/mappings/ihs.rb")

  BH_VISIT_FILE = "9002011"
  HF_FILE = "9002011.08"
  HF_TYPE_FILE = "9999999.64"
  HF_XREF = "AD"
  HF_READ_FIELDS = ".01E;.02;.03;.04E;.06;81101"
  HF_FLAGS = "IP"
  HF_MAX = "25"
  PRE_EDIT_FIELDS = ".08;1112"
  PRE_EDIT_FLAGS = "I"

  STOCK_HF_NAME = "CURRENT SMOKER, STATUS UNKNOWN"
  PREFIX_HF_NAME = "CURRENT SMOKER"

  PATIENT = "990543"
  OTHER_PATIENT = "990544"
  RECORD_IEN = "8801"
  RECORD_ADD = "8802"

  TWO_BYTE_CHAR = "\u00e9"
  COLLISION_NAME = "SYN FACTOR COLLISION ABCDEFGHIJKLMNOPQRS"

  HF_ONE_NAME = "SYN FACTOR A"
  HF_ONE_LEVEL = "MODERATE"
  HF_ONE_QTY = "2"
  HF_ONE_COMMENT = "SYN HF ONE"
  HF_TWO_NAME = "SYN FACTOR B"
  HF_TWO_LEVEL = "MINIMAL"
  HF_TWO_QTY = ""
  HF_TWO_COMMENT = ""

  WIRE_EDIT_TWO =
    "E|#{RECORD_IEN}|#{HF_ONE_NAME}~#{HF_ONE_LEVEL}~#{HF_ONE_QTY}~#{HF_ONE_COMMENT}*" \
    "#{HF_TWO_NAME}~#{HF_TWO_LEVEL}~#{HF_TWO_QTY}~#{HF_TWO_COMMENT}|#{PATIENT}".freeze

  WIRE_ADD_ONE =
    "A|#{RECORD_ADD}|#{HF_ONE_NAME}~#{HF_ONE_LEVEL}~#{HF_ONE_QTY}~#{HF_ONE_COMMENT}|#{PATIENT}".freeze

  EDIT_KWARGS = {
    record_ien: RECORD_IEN,
    patient: PATIENT,
    mode: :edit,
    health_factors: [
      { name: HF_ONE_NAME, level: HF_ONE_LEVEL, quantity: HF_ONE_QTY, comment: HF_ONE_COMMENT },
      { name: HF_TWO_NAME, level: HF_TWO_LEVEL, quantity: HF_TWO_QTY, comment: HF_TWO_COMMENT }
    ]
  }.freeze

  ADD_KWARGS = {
    record_ien: RECORD_ADD,
    patient: PATIENT,
    mode: :add,
    health_factors: [
      { name: HF_ONE_NAME, level: HF_ONE_LEVEL, quantity: HF_ONE_QTY, comment: HF_ONE_COMMENT }
    ]
  }.freeze

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_edit_pins_the_exact_four_piece_wire_with_star_joined_hf_items
    seed_amhg_only(WIRE_EDIT_TWO, RECORD_IEN, **EDIT_KWARGS)
    assert_raises(BH::SaveError) { BH.save_health_factors(**EDIT_KWARGS) }

    call = save_call
    refute_nil call
    assert_equal RPC, call[:rpc]
    assert_equal WIRE_EDIT_TWO, call[:params].first
    pieces = call[:params].first.split("|", -1)
    assert_equal 4, pieces.length
    assert_equal "E", pieces[0]
  end

  def test_add_pins_mode_a_on_the_wire
    seed_amhg_only(WIRE_ADD_ONE, RECORD_ADD, **ADD_KWARGS)
    assert_raises(BH::SaveError) { BH.save_health_factors(**ADD_KWARGS) }

    assert_equal "A", save_call[:params].first.split("|", -1)[0]
    assert_equal WIRE_ADD_ONE, save_call[:params].first
  end

  def test_save_health_factors_runs_under_amhgrpc_and_restores_the_callers_context
    seed_amhg_only(WIRE_EDIT_TWO, RECORD_IEN, **EDIT_KWARGS)
    caller_context = @mock.current_context

    assert_raises(BH::SaveError) { BH.save_health_factors(**EDIT_KWARGS) }

    assert_equal "AMHGRPC", save_call[:context]
    assert_equal caller_context, @mock.current_context
  end

  def test_edit_success_returns_record_ien_after_pre_edit_and_hf_lister_readback
    seed_success(RECORD_IEN, **EDIT_KWARGS)
    assert_equal RECORD_IEN, BH.save_health_factors(**EDIT_KWARGS)
    assert_hf_lister_after_save(RECORD_IEN)
  end

  def test_pre_edit_refuses_wrong_patient
    seed_pre_edit_patient(RECORD_IEN, OTHER_PATIENT)
    seed_hf_type_valid(HF_ONE_NAME)
    assert_pre_call_refusal(**EDIT_KWARGS.merge(health_factors: [ single_factor ]))
  end

  def test_pre_edit_refuses_signed_visit
    seed_pre_edit_patient(RECORD_IEN, PATIENT, signed: true)
    seed_hf_type_valid(HF_ONE_NAME)
    err = assert_raises(BH::SaveError) { BH.save_health_factors(**EDIT_KWARGS.merge(health_factors: [ single_factor ])) }
    assert_match(/signed/i, err.message)
    assert_empty amhg_calls
  end

  def test_refuses_level_outside_dd_set_before_rpc
    %w[YES NO minimal MINIMAL\  M].each do |bad_level|
      kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(level: bad_level) ])
      seed_pre_edit_patient(RECORD_IEN, PATIENT)
      seed_hf_type_valid(HF_ONE_NAME)
      assert_pre_call_refusal(**kwargs, label: bad_level.inspect)
    end
  end

  def test_accepts_level_from_dd_set_or_blank
    [ "", "MINIMAL", "MODERATE", "HEAVY/SEVERE" ].each do |level|
      kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(level: level, quantity: "1", comment: "SYN") ])
      seed_success(RECORD_IEN, **kwargs)
      assert_equal RECORD_IEN, BH.save_health_factors(**kwargs), "level #{level.inspect} should succeed"
    end
  end

  def test_refuses_invalid_quantity_before_rpc
    %w[
      abc -1 100000 1.555 01 1. \ 1
      0.5 1.50 1.0 00 0.0 +1 1e2
    ].each do |bad_qty|
      kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(quantity: bad_qty) ])
      seed_pre_edit_patient(RECORD_IEN, PATIENT)
      seed_hf_type_valid(HF_ONE_NAME)
      assert_pre_call_refusal(**kwargs, label: bad_qty.inspect)
    end
  end

  def test_accepts_valid_quantity_or_blank
    [ "", "0", "1", "2.5", ".5", ".25", "12.05", "99999" ].each do |qty|
      kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(level: "MINIMAL", quantity: qty, comment: "SYN") ])
      seed_success(RECORD_IEN, **kwargs)
      assert_equal RECORD_IEN, BH.save_health_factors(**kwargs), "quantity #{qty.inspect} should succeed"
    end
  end

  def test_refuses_comment_longer_than_245_characters_before_rpc
    long = "X" * 246
    kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(comment: long) ])
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_hf_type_valid(HF_ONE_NAME)
    assert_pre_call_refusal(**kwargs)
  end

  def test_refuses_comment_over_245_bytes_before_rpc
    long = TWO_BYTE_CHAR * 123
    assert_equal 246, long.bytesize
    assert_equal 123, long.length
    kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(comment: long) ])
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_hf_type_valid(HF_ONE_NAME)
    assert_pre_call_refusal(**kwargs)
  end

  def test_accepts_comment_of_245_characters
    comment = "C" * 245
    kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(level: "MINIMAL", comment: comment) ])
    seed_success(RECORD_IEN, **kwargs)
    assert_equal RECORD_IEN, BH.save_health_factors(**kwargs)
  end

  def test_accepts_comment_of_245_bytes
    comment = (TWO_BYTE_CHAR * 122) + "A"
    assert_equal 245, comment.bytesize
    kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(level: "MINIMAL", comment: comment) ])
    seed_success(RECORD_IEN, **kwargs)
    assert_equal RECORD_IEN, BH.save_health_factors(**kwargs)
  end

  def test_accepts_name_of_exactly_40_bytes
    name = "N" * 40
    kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(name: name) ])
    seed_success(RECORD_IEN, **kwargs)
    assert_equal RECORD_IEN, BH.save_health_factors(**kwargs)
  end

  def test_accepts_name_of_31_bytes
    name = "N" * 31
    kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(name: name) ])
    seed_success(RECORD_IEN, **kwargs)
    assert_equal RECORD_IEN, BH.save_health_factors(**kwargs)
  end

  def test_refuses_blank_name_before_rpc
    kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(name: "  ") ])
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    assert_pre_call_refusal(**kwargs)
  end

  def test_refuses_name_longer_than_40_characters_before_rpc
    long_name = "N" * 41
    kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(name: long_name) ])
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    assert_pre_call_refusal(**kwargs)
    refute hf_type_lister_called?(long_name), "name pre-read must not run for over-40-byte names"
  end

  def test_refuses_name_over_40_bytes_before_rpc
    name = TWO_BYTE_CHAR * 21
    assert_equal 42, name.bytesize
    assert_equal 21, name.length
    kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(name: name) ])
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    assert_pre_call_refusal(**kwargs)
    refute hf_type_lister_called?(name), "name pre-read must not run for over-40-byte names"
  end

  def test_refuses_name_when_pre_read_shows_no_row
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_hf_type_lister(HF_ONE_NAME, [])
    assert_pre_call_refusal(**EDIT_KWARGS.merge(health_factors: [ single_factor ]))
  end

  def test_refuses_name_when_pre_read_shows_prefix_match_only
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_hf_type_lister(STOCK_HF_NAME, [ type_row(ien: "77", name: PREFIX_HF_NAME) ])
    kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(name: STOCK_HF_NAME) ])
    assert_pre_call_refusal(**kwargs)
  end

  def test_refuses_name_when_pre_read_shows_category_entry
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_hf_type_lister(HF_ONE_NAME, [ type_row(entry_type: "C") ])
    assert_pre_call_refusal(**EDIT_KWARGS.merge(health_factors: [ single_factor ]))
  end

  def test_refuses_name_when_pre_read_shows_inactive_entry
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_hf_type_lister(HF_ONE_NAME, [ type_row(inactive: "1") ])
    assert_pre_call_refusal(**EDIT_KWARGS.merge(health_factors: [ single_factor ]))
  end

  def test_refuses_name_when_pre_read_shows_two_exact_rows
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_hf_type_lister(HF_ONE_NAME, [ type_row(ien: "1"), type_row(ien: "2") ])
    assert_pre_call_refusal(**EDIT_KWARGS.merge(health_factors: [ single_factor ]))
  end

  def test_refuses_name_when_pre_read_shows_b_subscript_collision_with_longer_active_row
    assert_equal 40, COLLISION_NAME.bytesize
    longer = "#{COLLISION_NAME} X"
    kwargs = EDIT_KWARGS.merge(
      health_factors: [ single_factor.merge(name: COLLISION_NAME, comment: "SYN COLLISION") ]
    )
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_hf_type_lister(
      COLLISION_NAME,
      [
        type_row(ien: "501", name: COLLISION_NAME, entry_type: "F"),
        type_row(ien: "502", name: longer, entry_type: "F")
      ]
    )
    assert_pre_call_refusal(**kwargs)
  end

  def test_name_pre_read_accepts_exact_row_alongside_longer_prefix_rows
    kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(name: PREFIX_HF_NAME) ])
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_hf_type_lister(
      PREFIX_HF_NAME,
      [
        type_row(ien: "501", name: PREFIX_HF_NAME, entry_type: "F"),
        type_row(ien: "77", name: STOCK_HF_NAME, entry_type: "F")
      ]
    )
    wire = wire_for(**kwargs)
    seed_amhg_text(wire, success_body(RECORD_IEN))
    seed_hf_readback(RECORD_IEN, hf_rows_for(**kwargs))
    assert_equal RECORD_IEN, BH.save_health_factors(**kwargs)
  end

  def test_name_pre_read_refuses_when_only_the_exact_row_is_a_category_among_prefix_rows
    kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(name: PREFIX_HF_NAME) ])
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_hf_type_lister(
      PREFIX_HF_NAME,
      [
        type_row(ien: "501", name: PREFIX_HF_NAME, entry_type: "C"),
        type_row(ien: "77", name: STOCK_HF_NAME, entry_type: "F")
      ]
    )
    assert_pre_call_refusal(**kwargs)
  end

  def test_refuses_name_when_pre_read_returns_error
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_hf_type_lister(HF_ONE_NAME, [], error: true)
    assert_pre_call_refusal(**EDIT_KWARGS.merge(health_factors: [ single_factor ]))
  end

  def test_refuses_name_when_pre_read_returns_data_and_error_block
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_hf_type_lister(HF_ONE_NAME, [ type_row ], errors_with_data: true)
    assert_pre_call_refusal(**EDIT_KWARGS.merge(health_factors: [ single_factor ]))
  end

  def test_refuses_name_when_pre_read_row_has_only_two_pieces
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_hf_type_lister_two_piece(HF_ONE_NAME, ien: "501", hf_name: HF_ONE_NAME)
    assert_pre_call_refusal(**EDIT_KWARGS.merge(health_factors: [ single_factor ]))
  end

  def test_refuses_name_when_pre_read_returns_more
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_hf_type_lister(HF_ONE_NAME, [ type_row ], more: true)
    assert_pre_call_refusal(**EDIT_KWARGS.merge(health_factors: [ single_factor ]))
  end

  def test_refuses_duplicate_name_in_one_call_before_rpc
    dup = single_factor
    kwargs = EDIT_KWARGS.merge(health_factors: [ dup, dup.merge(comment: "OTHER") ])
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_hf_type_valid(HF_ONE_NAME)
    assert_pre_call_refusal(**kwargs)
  end

  def test_refuses_empty_health_factors_list_in_edit_mode_before_rpc
    kwargs = EDIT_KWARGS.merge(health_factors: [])
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    assert_pre_call_refusal(**kwargs)
  end

  def test_refuses_empty_health_factors_list_in_add_mode_before_rpc
    kwargs = ADD_KWARGS.merge(health_factors: [])
    seed_pre_edit_patient(RECORD_ADD, PATIENT)
    assert_pre_call_refusal(**kwargs)
  end

  def test_edit_readback_mismatch_on_comment_raises_unconfirmed
    row = hf_rows_for(**EDIT_KWARGS.merge(health_factors: [ single_factor ])).first
    row = row.merge(comment: "DIFFERENT")
    assert_post_call_readback_miss(**EDIT_KWARGS.merge(health_factors: [ single_factor ]), readback_rows: [ row ])
  end

  def test_edit_readback_extra_row_raises_unconfirmed
    sent = hf_rows_for(**EDIT_KWARGS.merge(health_factors: [ single_factor ]))
    extra = sent.first.merge(ien: "2", name: "SYN FACTOR Z")
    assert_post_call_readback_miss(**EDIT_KWARGS.merge(health_factors: [ single_factor ]), readback_rows: sent + [ extra ])
  end

  def test_edit_readback_exact_match_returns_record_ien
    kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor ])
    seed_success(RECORD_IEN, **kwargs)
    assert_equal RECORD_IEN, BH.save_health_factors(**kwargs)
  end

  def test_add_readback_extra_row_still_returns_record_ien
    kwargs = ADD_KWARGS
    sent = hf_rows_for(**kwargs)
    extra = sent.first.merge(ien: "2", name: "SYN FACTOR Z")
    seed_pre_edit_patient(RECORD_ADD, PATIENT)
    seed_hf_type_valid(HF_ONE_NAME)
    seed_amhg_text(wire_for(**kwargs), success_body(RECORD_ADD))
    seed_hf_readback(RECORD_ADD, sent + [ extra ])
    assert_equal RECORD_ADD, BH.save_health_factors(**kwargs)
  end

  def test_add_readback_missing_sent_factor_raises_unconfirmed
    other = {
      ien: "99", name: "SYN FACTOR OTHER", patient: PATIENT, record: RECORD_ADD,
      level: "MINIMAL", quantity: "1", comment: "OTHER"
    }
    assert_post_call_readback_miss(**ADD_KWARGS, readback_rows: [ other ])
  end

  def test_readback_wrong_patient_raises_ambiguous
    row = hf_rows_for(**EDIT_KWARGS.merge(health_factors: [ single_factor ])).first
    row = row.merge(patient: OTHER_PATIENT)
    assert_post_call_readback_miss(**EDIT_KWARGS.merge(health_factors: [ single_factor ]), readback_rows: [ row ])
  end

  def test_readback_wrong_record_raises_ambiguous
    row = hf_rows_for(**EDIT_KWARGS.merge(health_factors: [ single_factor ])).first
    row = row.merge(record: "9999")
    assert_post_call_readback_miss(**EDIT_KWARGS.merge(health_factors: [ single_factor ]), readback_rows: [ row ])
  end

  def test_readback_error_block_raises_ambiguous
    assert_post_call_readback_miss(**EDIT_KWARGS.merge(health_factors: [ single_factor ]), readback_error: true)
  end

  def test_readback_data_and_error_block_raises_unconfirmed
    rows = hf_rows_for(**EDIT_KWARGS.merge(health_factors: [ single_factor ]))
    assert_post_call_readback_miss(
      **EDIT_KWARGS.merge(health_factors: [ single_factor ]), readback_rows: rows, readback_errors_with_data: true
    )
  end

  def test_readback_row_with_extra_piece_raises_unconfirmed
    row = hf_rows_for(**EDIT_KWARGS.merge(health_factors: [ single_factor ])).first
    assert_post_call_readback_miss(
      **EDIT_KWARGS.merge(health_factors: [ single_factor ]), readback_lines: [ "#{row[:ien]}^#{row[:name]}^#{row[:patient]}^#{row[:record]}^#{row[:level]}^#{row[:quantity]}^#{row[:comment]}^EXTRA" ]
    )
  end

  def test_readback_non_numeric_ien_raises_unconfirmed
    row = hf_rows_for(**EDIT_KWARGS.merge(health_factors: [ single_factor ])).first.merge(ien: "0")
    assert_post_call_readback_miss(**EDIT_KWARGS.merge(health_factors: [ single_factor ]), readback_rows: [ row ])
  end

  def test_readback_alpha_ien_raises_unconfirmed
    row = hf_rows_for(**EDIT_KWARGS.merge(health_factors: [ single_factor ])).first.merge(ien: "ABC")
    assert_post_call_readback_miss(**EDIT_KWARGS.merge(health_factors: [ single_factor ]), readback_rows: [ row ])
  end

  def test_readback_more_row_raises_ambiguous
    row = hf_rows_for(**EDIT_KWARGS.merge(health_factors: [ single_factor ])).first
    assert_post_call_readback_miss(
      **EDIT_KWARGS.merge(health_factors: [ single_factor ]), readback_rows: [ row ], readback_more: true
    )
  end

  def test_readback_empty_level_matches_sent_empty
    kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(level: "", quantity: "1", comment: "SYN") ])
    seed_success(RECORD_IEN, **kwargs)
    assert_equal RECORD_IEN, BH.save_health_factors(**kwargs)
  end

  def test_readback_moderate_level_must_not_read_back_blank
    kwargs = EDIT_KWARGS.merge(health_factors: [ single_factor.merge(level: "MODERATE", quantity: "1", comment: "SYN") ])
    row = hf_rows_for(**kwargs).first.merge(level: "")
    assert_post_call_readback_miss(**kwargs, readback_rows: [ row ])
  end

  def test_refuses_blank_record_ien_on_edit_without_rpc
    assert_pre_call_refusal(**EDIT_KWARGS.merge(record_ien: ""))
    assert_pre_call_refusal(**EDIT_KWARGS.merge(record_ien: "   "))
  end

  def test_refuses_blank_record_ien_on_add_without_rpc
    assert_pre_call_refusal(**ADD_KWARGS.merge(record_ien: ""))
  end

  def test_raises_on_zero_tilde_error_reply
    seed_post_amhg_trap(WIRE_EDIT_TWO, **EDIT_KWARGS) do
      seed_amhg_text(WIRE_EDIT_TWO, "T00030Result#{RS}0~Add Health Factor#{RS}#{US}")
    end
    err = assert_raises(BH::SaveError) { BH.save_health_factors(**EDIT_KWARGS) }
    assert_amhg_reached
    assert_match(/Add Health Factor|outcome unknown|may have been/i, err.message)
  end

  def test_raises_on_empty_reply
    seed_post_amhg_trap(WIRE_EDIT_TWO, **EDIT_KWARGS) { seed_amhg_text(WIRE_EDIT_TWO, "") }
    assert_raises(BH::SaveError) { BH.save_health_factors(**EDIT_KWARGS) }
  end

  def test_refuses_pipe_tilde_star_and_control_characters_in_hf_comment_without_rpc
    [ "|", "~", "*", "^", RS, "\n" ].each do |bad|
      factors = [ { name: HF_ONE_NAME, level: HF_ONE_LEVEL, quantity: "1", comment: "SYN#{bad}" } ]
      assert_input_validation_refusal(/separator|control/i, **EDIT_KWARGS.merge(health_factors: factors))
    end
  end

  def test_refuses_at_sign_in_comment_level_and_quantity_before_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_hf_type_valid(HF_ONE_NAME)
    assert_pre_call_refusal(**EDIT_KWARGS.merge(health_factors: [ single_factor.merge(comment: "@") ]))
    assert_pre_call_refusal(**EDIT_KWARGS.merge(health_factors: [ single_factor.merge(level: "@") ]))
    assert_pre_call_refusal(**EDIT_KWARGS.merge(health_factors: [ single_factor.merge(quantity: "@") ]))
  end

  def test_refuses_more_than_25_health_factors_before_any_rpc
    factors = (1..26).map do |n|
      { name: format("SYN HF LIMIT %02d", n), level: "MINIMAL", quantity: "1", comment: "X" }
    end
    kwargs = EDIT_KWARGS.merge(health_factors: factors)
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    assert_pre_call_refusal(**kwargs)
    refute ddr_lister_calls.any? { |c| c[:params].first.to_s.include?(HF_TYPE_FILE) },
           "must not pre-read 9999999.64 when the list is over the read-back max"
    assert_empty amhg_calls
  end

  def test_refuses_pipe_in_hf_name_or_level_without_rpc
    assert_input_validation_refusal(/separator|control/i,
                                   **EDIT_KWARGS.merge(health_factors: [
                                     { name: "BAD|NAME", level: HF_ONE_LEVEL, quantity: "1", comment: "" }
                                   ]))
    assert_input_validation_refusal(/separator|control/i,
                                   **EDIT_KWARGS.merge(health_factors: [
                                     { name: HF_ONE_NAME, level: "A|B", quantity: "1", comment: "" }
                                   ]))
  end

  def test_retry_safety_classifies_save_health_factors_as_non_idempotent_write
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(BH, :save_health_factors)
  end

  def test_required_rpcs_lists_amhg_save_health_factors_under_behavioral_health
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    assert_includes doc.fetch("modules").fetch("RpmsRpc::BehavioralHealth"), RPC
  end

  def test_rpcs_md_documents_save_health_factors_verified_under_amhgrpc
    text = File.read(RPCS_MD_PATH, encoding: Encoding::UTF_8)
    bh_section = text[/## Behavioral Health writes.*?^(?=## |\z)/m]
    refute_nil bh_section, "Behavioral Health section missing from docs/rpcs.md"
    assert_includes bh_section, "bcer-9.0-20261012-e7923a4-ydb"
    row = bh_section.lines.find { |line| line.include?("`AMHG SAVE HEALTH FACTORS`") }
    refute_nil row
    assert_match(/\|\s*verified\s*\|\s*\z/, row.strip)
    assert_includes text, "HF^AMHGSVF"
    assert_includes text, "AMHGRPC"
  end

  def test_mappings_ihs_defines_amhg_save_health_factors
    assert_includes File.read(MAPPINGS_PATH), "DataMapper.define(:amhg_save_health_factors)",
                    "production mapping :amhg_save_health_factors must ship with save_health_factors"
  end

  private

  def single_factor
    { name: HF_ONE_NAME, level: "MINIMAL", quantity: "1", comment: "SYN HF" }
  end

  def type_row(ien: "501", name: HF_ONE_NAME, entry_type: "F", inactive: "")
    { ien: ien, name: name, entry_type: entry_type, inactive: inactive }
  end

  def save_call
    @mock.received_calls.find { |c| c[:rpc] == RPC }
  end

  def amhg_calls
    @mock.received_calls.select { |c| c[:rpc] == RPC }
  end

  def assert_amhg_reached
    refute_empty amhg_calls
  end

  def seed_amhg_text(wire, body)
    @mock.seed_text(:amhg_save_health_factors, wire, body)
  end

  def success_body(ien)
    "T00030Result#{RS}#{ien}#{RS}#{US}"
  end

  def hf_readback_screen(record_ien)
    "I $P(^(0),U,3)=#{record_ien}"
  end

  def hf_readback_lister_key(record_ien)
    Ddr.lister_param(
      file: HF_FILE, xref: HF_XREF, part: record_ien.to_s,
      screen: hf_readback_screen(record_ien),
      fields: HF_READ_FIELDS, flags: HF_FLAGS, max: HF_MAX
    ).to_s
  end

  def hf_type_lister_key(name)
    Ddr.lister_param(
      file: HF_TYPE_FILE, xref: "B", part: name, fields: ".01;.1;.13", flags: HF_FLAGS, max: HF_MAX
    ).to_s
  end

  def hf_rows_for(**kwargs)
    kwargs.fetch(:health_factors, []).map.with_index(1) do |row, idx|
      {
        ien: idx.to_s,
        name: row.fetch(:name).to_s,
        patient: kwargs.fetch(:patient, PATIENT).to_s,
        record: kwargs.fetch(:record_ien, RECORD_IEN).to_s,
        level: row.fetch(:level, "").to_s,
        quantity: row.fetch(:quantity, "").to_s,
        comment: row.fetch(:comment, "").to_s
      }
    end
  end

  def hf_readback_body(rows, more: false, error: false, errors_with_data: false, lines: nil)
    return "[Errors]" if error && !errors_with_data

    packed =
      lines ||
      rows.map do |row|
        "#{row[:ien]}^#{row[:name]}^#{row[:patient]}^#{row[:record]}^#{row[:level]}^" \
          "#{row[:quantity]}^#{row[:comment]}"
      end
    data = "[Data]\n#{Array(packed).join("\n")}"
    body = errors_with_data ? "[Errors]\n#{data}" : data
    more ? "[Misc]\nMORE^1^1\n#{body}" : body
  end

  def seed_hf_readback(record_ien, rows, more: false, error: false, errors_with_data: false, lines: nil)
    @mock.seed(
      :ddr_lister, hf_readback_lister_key(record_ien),
      hf_readback_body(rows, more: more, error: error, errors_with_data: errors_with_data, lines: lines)
    )
  end

  def seed_hf_type_lister(name, rows, error: false, more: false, errors_with_data: false)
    body =
      if error
        "[ERROR]"
      elsif rows.empty?
        "[Data]"
      else
        packed = rows.map { |r| "#{r[:ien]}^#{r[:name]}^#{r[:entry_type]}^#{r[:inactive]}" }
        data = "[Data]\n#{packed.join("\n")}"
        data = "[Errors]\n#{data}" if errors_with_data
        more ? "[Misc]\nMORE^1^1\n#{data}" : data
      end
    @mock.seed(:ddr_lister, hf_type_lister_key(name), body)
  end

  def seed_hf_type_lister_two_piece(part, ien:, hf_name:)
    @mock.seed(:ddr_lister, hf_type_lister_key(part), "[Data]\n#{ien}^#{hf_name}")
  end

  def seed_hf_type_valid(name)
    seed_hf_type_lister(name, [ type_row(name: name) ])
  end

  def hf_type_lister_called?(name)
    key = hf_type_lister_key(name)
    @mock.received_calls.any? { |c| c[:rpc] == "DDR LISTER" && c[:params].first.to_s == key }
  end

  def seed_success(ien, **kwargs)
    seed_amhg_only(wire_for(**kwargs), ien, **kwargs)
    seed_hf_readback(kwargs.fetch(:record_ien), hf_rows_for(**kwargs))
  end

  def seed_amhg_only(wire, _ien, **kwargs)
    seed_pre_edit_patient(kwargs.fetch(:record_ien), kwargs.fetch(:patient))
    kwargs.fetch(:health_factors, []).map { |r| r[:name] }.uniq.each { |n| seed_hf_type_valid(n) }
    seed_amhg_text(wire, success_body(kwargs.fetch(:record_ien)))
  end

  def seed_post_amhg_trap(wire, **kwargs)
    seed_pre_edit_patient(kwargs.fetch(:record_ien), kwargs.fetch(:patient))
    kwargs.fetch(:health_factors, []).map { |r| r[:name] }.uniq.each { |n| seed_hf_type_valid(n) }
    yield if block_given?
  end

  def seed_pre_edit_patient(ien, patient, signed: false)
    key = Ddr.gets_entry_param(
      file: BH_VISIT_FILE, iens: "#{ien},", fields: PRE_EDIT_FIELDS, flags: PRE_EDIT_FLAGS
    ).to_s
    signed_at = signed ? "3251031.12" : ""
    body = <<~BODY
      [Data]
      #{BH_VISIT_FILE}^#{ien}^.08^#{patient}^PATIENT,SYNTH
      #{BH_VISIT_FILE}^#{ien}^1112^#{signed_at}^SIGNED
    BODY
    @mock.seed(:ddr_gets_entry_data, key, body)
  end

  def assert_hf_lister_after_save(record_ien)
    idx_save = @mock.received_calls.index { |c| c[:rpc] == RPC }
    refute_nil idx_save
    later = @mock.received_calls[(idx_save + 1)..]
    refute_nil later.find { |c| c[:rpc] == "DDR LISTER" && c[:params].first.to_s.include?(HF_FILE) },
               "expected HF DDR LISTER read-back after #{RPC}"
  end

  def assert_pre_call_refusal(**kwargs)
    label = kwargs.delete(:label)
    before = amhg_calls.length
    assert_raises(BH::SaveError) { BH.save_health_factors(**kwargs) }
    assert_equal before, amhg_calls.length, "pre-call refusal must not RPC#{label ? " (#{label})" : ""}"
  end

  def assert_input_validation_refusal(pattern, **kwargs)
    err = assert_raises(BH::SaveError) { BH.save_health_factors(**kwargs) }
    assert_empty amhg_calls
    assert_match pattern, err.message
  end

  def ddr_lister_calls
    @mock.received_calls.select { |c| c[:rpc] == "DDR LISTER" }
  end

  def assert_post_call_readback_miss(**kwargs)
    wire = kwargs.delete(:wire)
    readback_rows = kwargs.delete(:readback_rows)
    readback_lines = kwargs.delete(:readback_lines)
    readback_more = kwargs.delete(:readback_more) || false
    readback_error = kwargs.delete(:readback_error) || false
    readback_errors_with_data = kwargs.delete(:readback_errors_with_data) || false
    record_ien = kwargs.fetch(:record_ien, RECORD_IEN)
    wire_param = wire || wire_for(**kwargs)
    seed_pre_edit_patient(record_ien, kwargs.fetch(:patient, PATIENT))
    kwargs.fetch(:health_factors, []).map { |r| r[:name] }.uniq.each { |n| seed_hf_type_valid(n) }
    seed_amhg_text(wire_param, success_body(record_ien))
    rows = readback_rows || hf_rows_for(**kwargs)
    seed_hf_readback(
      record_ien, rows, more: readback_more, error: readback_error,
      errors_with_data: readback_errors_with_data, lines: readback_lines
    )
    err = assert_raises(BH::SaveError) { BH.save_health_factors(**kwargs) }
    assert_amhg_reached
    assert_match(/may have been|outcome unknown|not confirmed/i, err.message)
    refute_includes err.message, PATIENT
  end

  def wire_for(**kwargs)
    letter = kwargs.fetch(:mode) == :add ? "A" : "E"
    record = kwargs.fetch(:record_ien, RECORD_IEN).to_s
    patient = kwargs.fetch(:patient, PATIENT).to_s
    listed = kwargs.fetch(:health_factors, []).map do |row|
      [
        row.fetch(:name).to_s,
        row.fetch(:level, "").to_s,
        row.fetch(:quantity, "").to_s,
        row.fetch(:comment, "").to_s
      ].join("~")
    end.join("*")
    [ letter, record, listed, patient ].join("|")
  end
end
