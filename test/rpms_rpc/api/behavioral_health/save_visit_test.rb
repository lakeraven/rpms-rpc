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

# AMHG SAVE VISIT — VISIT^AMHGSVF (AMHGSVF.m), MODV^AMHGEVF (AMHGEVF.m).
# Mock seeds use mapping :amhg_save_visit → RPC "AMHG SAVE VISIT".
# Revised contract (rpms-rpc#536): edit fields explicit, pre-edit .08 check,
# post-call DDR read-back confirmation, no e-sign piece, caret/time guards.
class BehavioralHealthSaveVisitTest < Minitest::Test
  BH = RpmsRpc::BehavioralHealth
  Ddr = RpmsRpc::DdrFileman
  RPC = "AMHG SAVE VISIT"
  RS = "\x1e" # $C(30)
  US = "\x1f" # $C(31)

  ROOT = File.expand_path("../../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  BH_VISIT_FILE = "9002011"
  PATIENT_FILE = "9000001"
  # Pinned: post-call DDR GETS field lists (group pieces filed only when name non-empty).
  READBACK_FIELDS = ".01;.02;.04;.05;.07;.08;.11;.25"
  READBACK_FIELDS_GROUP = ".01;.02;.04;.05;.07;.08;.11;.25;.12;.34;1104;1109"
  READBACK_FLAGS = "IE"
  # Pinned: before an add, patient must exist via DDR in the caller's context.
  PRE_ADD_PATIENT_FIELDS = ".01"
  PRE_ADD_PATIENT_FLAGS = "I"
  # Pinned: before an edit, #9002011 .08 and 1112 (DATE/TIME NOTE SIGNED); non-blank 1112 refuses.
  PRE_EDIT_VISIT_FIELDS = ".08;1112"
  PRE_EDIT_VISIT_FLAGS = "I"
  # Pinned: #9002011.02 primaries for a visit — DDR LISTER on xref AD with SCREEN on .03 (MHSS RECORD).
  # Live-verified: PART=1 prefix-matches visits 1,10,11..19; SCREEN I $P(^(0),U,3)=<visit> returns only that visit.
  PROVIDER_FILE = "9002011.02"
  PROVIDER_LOOKUP_XREF = "AD"
  PROVIDER_LOOKUP_FROM = "0"
  PROVIDER_LOOKUP_FIELDS = ".01;.02;.03;.04"
  PROVIDER_LOOKUP_FLAGS = "IP"
  PROVIDER_LOOKUP_MAX = "25"
  # Pinned: before AMHG, each non-blank pointer gets DDR GETS .01 (iens "<ien>,", flags "I").
  CLINIC_FILE = "40.7"
  TYPE_OF_CONTACT_FILE = "9002012.1"
  ENCOUNTER_LOCATION_FILE = "9999999.06"
  COMMUNITY_FILE = "9999999.05"
  PROVIDER_DUZ_FILE = "200"
  PRE_POINTER_FIELDS = ".01"
  PRE_POINTER_FLAGS = "I"
  DANGLING_CLINIC = "999999"
  DATE_BEFORE_DD_MIN = "1891231"
  DATE_AFTER_TODAY = "3991231"
  # DD marks .06 ACTIVITY TYPE "R" on ^DD(9002011,.06,0); AMHG SAVE VISIT has no wire piece for it.

  PATIENT = "990536"
  OTHER_PATIENT = "990537"
  PROVIDER = "412"
  RECORD_IEN = "8801"
  ENCOUNTER = "3251031.0930"
  PROGRAM = "MENTAL HEALTH"
  PROGRAM_INTERNAL = "M"
  CLINIC = "17"
  TYPE_OF_CONTACT = "3"
  ENCOUNTER_LOCATION = "55"
  COMMUNITY_OF_SERVICE = "42"
  APPOINTMENT_WITH = "APPOINTMENT"
  APPOINTMENT_INTERNAL = "A"
  GROUP_NAME = "SYNTH GROUP ALPHA"
  GROUP_TIME = "45"
  ACTIVITY_TIME = "30"

  EDIT_EXPLICIT_KEYS = %i[
    program clinic type_of_contact encounter_location community_of_service appointment_with group_name
  ].freeze

  # VISIT^AMHGSVF: 16 pieces. Piece 7 (ARR) blank; piece 15 (e-sign) always blank.
  WIRE_ADD_FULL =
    "A||#{PROVIDER}|#{PROGRAM}|#{CLINIC}|#{TYPE_OF_CONTACT}||#{ENCOUNTER}|#{ENCOUNTER_LOCATION}|" \
    "#{APPOINTMENT_WITH}|#{COMMUNITY_OF_SERVICE}|#{PATIENT}|#{GROUP_NAME}|#{GROUP_TIME}||#{ACTIVITY_TIME}".freeze

  WIRE_ADD_REQUIRED_ONLY =
    "A||#{PROVIDER}|#{PROGRAM}|#{CLINIC}|#{TYPE_OF_CONTACT}||#{ENCOUNTER.split('.').first}|" \
    "#{ENCOUNTER_LOCATION}||#{COMMUNITY_OF_SERVICE}|#{PATIENT}||||".freeze

  WIRE_EDIT_FULL =
    "E|#{RECORD_IEN}|#{PROVIDER}|#{PROGRAM}|#{CLINIC}|#{TYPE_OF_CONTACT}||#{ENCOUNTER}|#{ENCOUNTER_LOCATION}|" \
    "#{APPOINTMENT_WITH}|#{COMMUNITY_OF_SERVICE}|#{PATIENT}|#{GROUP_NAME}|#{GROUP_TIME}||#{ACTIVITY_TIME}".freeze

  WIRE_EDIT_NO_GROUP_CHANGE =
    "E|#{RECORD_IEN}|#{PROVIDER}|#{PROGRAM}|#{CLINIC}|#{TYPE_OF_CONTACT}||#{ENCOUNTER}|#{ENCOUNTER_LOCATION}|" \
    "#{APPOINTMENT_WITH}|#{COMMUNITY_OF_SERVICE}|#{PATIENT}||||".freeze

  FULL_KWARGS = {
    provider: PROVIDER,
    program: PROGRAM,
    clinic: CLINIC,
    type_of_contact: TYPE_OF_CONTACT,
    encounter_date: ENCOUNTER,
    encounter_location: ENCOUNTER_LOCATION,
    community_of_service: COMMUNITY_OF_SERVICE,
    appointment_with: APPOINTMENT_WITH,
    patient: PATIENT,
    group_name: GROUP_NAME,
    group_time: GROUP_TIME,
    activity_time: ACTIVITY_TIME
  }.freeze

  REQUIRED_KWARGS = {
    provider: PROVIDER,
    encounter_date: ENCOUNTER.split(".").first,
    patient: PATIENT,
    program: PROGRAM,
    clinic: CLINIC,
    type_of_contact: TYPE_OF_CONTACT,
    encounter_location: ENCOUNTER_LOCATION,
    community_of_service: COMMUNITY_OF_SERVICE
  }.freeze

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # --- wire shape (VISIT^AMHGSVF) -------------------------------------------

  def test_add_pins_the_exact_sixteen_piece_wire_string_with_all_fields
    seed_add_success(WIRE_ADD_FULL, "8802", **FULL_KWARGS)
    BH.save_visit(**FULL_KWARGS)

    call = save_call
    refute_nil call, "expected #{RPC}"
    assert_equal 1, call[:params].length,
                 "AMHG rejects multi-actual calls with YDB-E-ACTLSTTOOLONG (#198)"
    assert_equal WIRE_ADD_FULL, call[:params].first
    assert_equal 16, call[:params].first.split("|", -1).length
    assert_equal "", call[:params].first.split("|", -1)[14], "piece 15 e-sign is always blank"
    assert_equal RPC, call[:rpc]
  end

  def test_add_pins_required_fields_only_with_blank_optional_pieces
    seed_add_success(WIRE_ADD_REQUIRED_ONLY, "8803", **REQUIRED_KWARGS)
    BH.save_visit(**REQUIRED_KWARGS)

    param = save_call[:params].first
    assert_equal WIRE_ADD_REQUIRED_ONLY, param
    assert_equal 16, param.split("|", -1).length
  end

  def test_edit_pins_the_exact_sixteen_piece_wire_string
    seed_edit_success(WIRE_EDIT_FULL, RECORD_IEN, **FULL_KWARGS)
    BH.save_visit(**FULL_KWARGS, record_ien: RECORD_IEN)

    param = save_call[:params].first
    assert_equal WIRE_EDIT_FULL, param
    assert_equal 16, param.split("|", -1).length
    assert_equal "", param.split("|", -1)[14]
  end

  def test_save_visit_runs_under_amhgrpc_and_restores_the_callers_context
    seed_add_success(WIRE_ADD_FULL, "8802", **FULL_KWARGS)
    caller_context = @mock.current_context

    BH.save_visit(**FULL_KWARGS)

    call = save_call
    assert_equal "AMHGRPC", call[:context]
    assert_equal caller_context, @mock.current_context
    assert_equal [ "AMHGRPC", caller_context ], @mock.context_binds
  end

  def test_add_success_returns_the_record_ien_from_the_t00010bmxien_row_after_readback
    seed_add_success(WIRE_ADD_FULL, "8802", **FULL_KWARGS)
    assert_equal "8802", BH.save_visit(**FULL_KWARGS)
    assert_readback_ddr_call("8802,", **FULL_KWARGS)
  end

  def test_edit_success_returns_the_requested_record_ien_after_pre_edit_check_and_readback
    seed_edit_success(WIRE_EDIT_FULL, RECORD_IEN, **FULL_KWARGS)
    assert_equal RECORD_IEN, BH.save_visit(**FULL_KWARGS, record_ien: RECORD_IEN)
    assert_pre_edit_ddr_call("#{RECORD_IEN},")
    assert_readback_ddr_call("#{RECORD_IEN},", **FULL_KWARGS)
  end

  def test_success_pins_ddr_gets_readback_fields_and_flags_without_group
    seed_add_success(WIRE_ADD_REQUIRED_ONLY, "8803", **REQUIRED_KWARGS)
    BH.save_visit(**REQUIRED_KWARGS)

    param = ddr_gets_calls.last[:params].first
    assert_equal READBACK_FIELDS, param["FIELDS"]
    assert_equal READBACK_FLAGS, param["FLAGS"]
    assert_equal BH_VISIT_FILE, param["FILE"]
  end

  def test_success_pins_ddr_gets_readback_fields_and_flags_with_group
    seed_add_success(WIRE_ADD_FULL, "8802", **FULL_KWARGS)
    BH.save_visit(**FULL_KWARGS)

    param = ddr_gets_calls.last[:params].first
    assert_equal READBACK_FIELDS_GROUP, param["FIELDS"]
    assert_equal READBACK_FLAGS, param["FLAGS"]
    assert_equal BH_VISIT_FILE, param["FILE"]
  end

  def test_add_pins_pre_add_patient_ddr_gets_on_file_9000001
    seed_add_success(WIRE_ADD_REQUIRED_ONLY, "8803", **REQUIRED_KWARGS)
    BH.save_visit(**REQUIRED_KWARGS)

    pre_positions = positions_of do |c|
      next false unless c[:rpc] == "DDR GETS ENTRY DATA"

      p = c[:params].first
      p["FILE"] == PATIENT_FILE && p["IENS"] == "#{PATIENT}," &&
        p["FIELDS"] == PRE_ADD_PATIENT_FIELDS && p["FLAGS"] == PRE_ADD_PATIENT_FLAGS
    end
    amhg_positions = positions_of { |c| c[:rpc] == RPC }
    refute_nil pre_positions.first, "expected pre-add patient DDR GETS"
    refute_nil amhg_positions.first, "expected AMHG SAVE VISIT"
    assert_operator pre_positions.first, :<, amhg_positions.first,
                    "pre-add patient read must precede AMHG SAVE VISIT"
  end

  def test_add_refuses_when_pre_add_patient_read_errors_without_amhg_rpc
    seed_patient_exists(PATIENT, error: true)
    assert_pre_call_refusal(**REQUIRED_KWARGS, label: "pre-add patient error")
    assert_empty amhg_calls
  end

  def test_add_refuses_when_pre_add_patient_read_is_empty_without_amhg_rpc
    seed_patient_exists(PATIENT, empty: true)
    assert_pre_call_refusal(**REQUIRED_KWARGS, label: "pre-add patient empty")
    assert_empty amhg_calls
  end

  def test_add_refuses_when_pre_add_patient_read_returns_nil_without_amhg_rpc
    # Unseeded DDR GETS → broker silence → gets_entry nil (not success).
    assert_pre_call_refusal(**REQUIRED_KWARGS, label: "pre-add patient nil")
    assert_empty amhg_calls
  end

  def test_add_refuses_when_pre_add_patient_dot01_is_blank_without_amhg_rpc
    seed_patient_exists(PATIENT, blank_dot01: true)
    assert_pre_call_refusal(**REQUIRED_KWARGS, label: "pre-add patient blank .01")
    assert_empty amhg_calls
  end

  def test_edit_pins_pre_and_post_provider_ddr_lister_on_ad_index
    seed_edit_success(WIRE_EDIT_NO_GROUP_CHANGE, RECORD_IEN,
                      **FULL_KWARGS.merge(record_ien: RECORD_IEN, group_name: "", group_time: nil, activity_time: nil))
    BH.save_visit(**FULL_KWARGS.merge(record_ien: RECORD_IEN, group_name: "", group_time: nil, activity_time: nil))

    param = Ddr.lister_param(
      file: PROVIDER_FILE, xref: PROVIDER_LOOKUP_XREF, part: RECORD_IEN.to_s,
      from: PROVIDER_LOOKUP_FROM, screen: provider_lookup_screen(RECORD_IEN),
      fields: PROVIDER_LOOKUP_FIELDS, flags: PROVIDER_LOOKUP_FLAGS, max: PROVIDER_LOOKUP_MAX
    )
    want = param.to_s
    lister_positions = positions_of do |c|
      c[:rpc] == "DDR LISTER" && c[:params].first.to_s == want
    end
    assert_equal 2, lister_positions.size, "expected pre- and post-call provider DDR LISTER on AD"
    assert_equal provider_lookup_screen(RECORD_IEN), param["SCREEN"]
    amhg_positions = positions_of { |c| c[:rpc] == RPC }
    refute_nil amhg_positions.first, "expected AMHG SAVE VISIT"
    pre_index = lister_positions.first
    post_index = lister_positions.last
    amhg_index = amhg_positions.first
    assert_operator pre_index, :<, amhg_index
    assert_operator amhg_index, :<, post_index
  end

  def test_edit_refuses_when_pre_edit_primary_provider_is_not_the_named_provider_without_amhg_rpc
    seed_patient_exists(PATIENT)
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_provider_lister(RECORD_IEN, provider: "999", patient: PATIENT)
    err = assert_raises(BH::SaveError) do
      BH.save_visit(**FULL_KWARGS.merge(record_ien: RECORD_IEN, group_name: "", group_time: nil, activity_time: nil))
    end
    assert_match(/changing the primary provider is not supported/i, err.message)
    assert_empty amhg_calls
  end

  def test_edit_refuses_when_pre_edit_primary_provider_lookup_is_ambiguous_without_amhg_rpc
    # FNDPRV^AMHGU calls CHNGPP (AMHGU.m:336-349): rewrites the existing primary .01; it does not add a second primary.
    seed_patient_exists(PATIENT)
    seed_pointer_reads(**FULL_KWARGS)
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_provider_lister(RECORD_IEN, provider: PROVIDER, patient: PATIENT, extra_primary: true)
    err = assert_raises(BH::SaveError) do
      BH.save_visit(**FULL_KWARGS.merge(record_ien: RECORD_IEN, group_name: "", group_time: nil, activity_time: nil))
    end
    assert_match(/changing the primary provider is not supported/i, err.message)
    assert_empty amhg_calls
  end

  def test_edit_ignores_foreign_visit_rows_in_pre_edit_provider_lister_and_reaches_amhg
    kwargs = FULL_KWARGS.merge(record_ien: RECORD_IEN, group_name: "", group_time: nil, activity_time: nil)
    seed_edit_success(WIRE_EDIT_NO_GROUP_CHANGE, RECORD_IEN, **kwargs, foreign_visit_row: true)
    BH.save_visit(**kwargs)
    refute_empty amhg_calls, "rows with .03 not equal to the visit must not block edit"
  end

  def test_edit_refuses_when_pre_edit_provider_lister_is_truncated_without_amhg_rpc
    seed_patient_exists(PATIENT)
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_provider_lister(RECORD_IEN, provider: PROVIDER, patient: PATIENT, more: true)
    err = assert_raises(BH::SaveError) do
      BH.save_visit(**FULL_KWARGS.merge(record_ien: RECORD_IEN, group_name: "", group_time: nil, activity_time: nil))
    end
    assert_match(/primary provider/i, err.message)
    assert_empty amhg_calls
  end

  def test_edit_refuses_when_pre_edit_provider_lister_errors_without_amhg_rpc
    seed_patient_exists(PATIENT)
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_provider_lister(RECORD_IEN, provider: PROVIDER, patient: PATIENT, error: true)
    err = assert_raises(BH::SaveError) do
      BH.save_visit(**FULL_KWARGS.merge(record_ien: RECORD_IEN, group_name: "", group_time: nil, activity_time: nil))
    end
    assert_match(/primary provider/i, err.message)
    assert_empty amhg_calls
  end

  def test_add_pins_pre_amhg_pointer_existence_ddr_gets_for_each_filed_pointer
    seed_add_success(WIRE_ADD_FULL, "8802", **FULL_KWARGS)
    BH.save_visit(**FULL_KWARGS)

    expected = pointer_ddr_expectations(**FULL_KWARGS)
    amhg_index = positions_of { |c| c[:rpc] == RPC }.first
    expected.each do |exp|
      idx = positions_of do |c|
        next false unless c[:rpc] == "DDR GETS ENTRY DATA"

        p = c[:params].first
        p["FILE"] == exp[:file] && p["IENS"] == exp[:iens] &&
          p["FIELDS"] == PRE_POINTER_FIELDS && p["FLAGS"] == PRE_POINTER_FLAGS
      end.first
      refute_nil idx, "expected pointer GETS on #{exp[:file]} #{exp[:iens]}"
      assert_operator idx, :<, amhg_index, "#{exp[:label]} existence read must precede AMHG SAVE VISIT"
    end
  end

  def test_add_refuses_dangling_clinic_without_amhg_rpc
    seed_pre_amhg_reads(**FULL_KWARGS)
    err = assert_pre_call_refusal(**FULL_KWARGS.merge(clinic: DANGLING_CLINIC), label: "dangling clinic")
    assert_match(/clinic/i, err.message)
    refute_match(/999999/, err.message)
  end

  def test_edit_pins_pre_edit_visit_ddr_gets_fields_and_flags
    seed_edit_success(WIRE_EDIT_FULL, RECORD_IEN, **FULL_KWARGS)
    BH.save_visit(**FULL_KWARGS, record_ien: RECORD_IEN)

    param = ddr_gets_calls.find do |c|
      next false unless c[:rpc] == "DDR GETS ENTRY DATA"

      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["IENS"] == "#{RECORD_IEN},"
    end[:params].first
    assert_equal PRE_EDIT_VISIT_FIELDS, param["FIELDS"]
    assert_equal PRE_EDIT_VISIT_FLAGS, param["FLAGS"]
    assert_equal "#{RECORD_IEN},", param["IENS"]
  end

  def test_edit_refuses_when_visit_is_signed_without_amhg_rpc
    seed_edit_preconditions(RECORD_IEN, signed: true)
    err = assert_raises(BH::SaveError) do
      BH.save_visit(**FULL_KWARGS.merge(record_ien: RECORD_IEN, group_name: "", group_time: nil, activity_time: nil))
    end
    assert_match(/signed/i, err.message)
    assert_empty amhg_calls
  end

  def test_rejects_esign_as_an_unknown_keyword
    err = assert_raises(ArgumentError) { BH.save_visit(**FULL_KWARGS, esign: true) }
    refute_empty err.message
    assert_empty @mock.received_calls, "unknown keyword must not RPC"
  end

  def test_rejects_arrival_time_as_an_unknown_keyword
    err = assert_raises(ArgumentError) { BH.save_visit(**FULL_KWARGS, arrival_time: "09:30") }
    refute_empty err.message
    assert_empty @mock.received_calls, "unknown keyword must not RPC"
  end

  # --- pre-call refusals (no RPC) -------------------------------------------

  def test_save_error_is_a_subclass_of_rpms_rpc_error
    assert_operator BH::SaveError, :<, RpmsRpc::Error
  end

  def test_refuses_missing_provider_without_rpc
    assert_pre_call_refusal(**FULL_KWARGS.merge(provider: nil))
    assert_pre_call_refusal(**FULL_KWARGS.merge(provider: ""))
    assert_pre_call_refusal(**FULL_KWARGS.merge(provider: "   "))
  end

  def test_refuses_missing_encounter_date_without_rpc
    assert_pre_call_refusal(**FULL_KWARGS.merge(encounter_date: nil))
    assert_pre_call_refusal(**FULL_KWARGS.merge(encounter_date: ""))
    assert_pre_call_refusal(**FULL_KWARGS.merge(encounter_date: "   "))
  end

  def test_refuses_missing_patient_without_rpc
    assert_pre_call_refusal(**FULL_KWARGS.merge(patient: nil))
    assert_pre_call_refusal(**FULL_KWARGS.merge(patient: ""))
    assert_pre_call_refusal(**FULL_KWARGS.merge(patient: "   "))
  end

  def test_refuses_missing_dd_required_fields_on_add_without_rpc
    %i[program clinic type_of_contact encounter_location community_of_service].each do |key|
      assert_pre_call_refusal(**REQUIRED_KWARGS.merge(key => nil), label: "add #{key} nil")
      assert_pre_call_refusal(**REQUIRED_KWARGS.merge(key => ""), label: "add #{key} blank")
    end
  end

  def test_refuses_missing_dd_required_fields_on_edit_without_rpc
    seed_edit_preconditions(RECORD_IEN)
    %i[program clinic type_of_contact encounter_location community_of_service].each do |key|
      assert_pre_call_refusal(**FULL_KWARGS.merge(record_ien: RECORD_IEN, key => nil), label: "edit #{key} nil")
      assert_pre_call_refusal(
        **FULL_KWARGS.merge(record_ien: RECORD_IEN, key => "", group_name: "", group_time: nil, activity_time: nil),
        label: "edit #{key} blank"
      )
    end
  end

  def test_refuses_non_positive_integer_patient_provider_or_record_ien_without_rpc
    assert_pre_call_refusal(**FULL_KWARGS.merge(patient: "0"))
    assert_pre_call_refusal(**FULL_KWARGS.merge(patient: "-1"))
    assert_pre_call_refusal(**FULL_KWARGS.merge(patient: "abc"))
    assert_pre_call_refusal(**FULL_KWARGS.merge(provider: "0"))
    assert_pre_call_refusal(**FULL_KWARGS.merge(record_ien: "0"))
    assert_pre_call_refusal(**FULL_KWARGS.merge(record_ien: "abc"))
  end

  def test_refuses_blank_record_ien_on_edit_without_rpc
    assert_pre_call_refusal(**FULL_KWARGS.merge(record_ien: ""))
    assert_pre_call_refusal(**FULL_KWARGS.merge(record_ien: "   "))
  end

  def test_refuses_invalid_encounter_date_without_rpc
    %w[yesterday 2026-10-31 326101 12345678 0251031].each do |bad|
      assert_pre_call_refusal(**FULL_KWARGS.merge(encounter_date: bad))
    end
  end

  def test_refuses_encounter_date_before_dd_minimum_or_after_today_without_rpc
    assert_pre_call_refusal(**FULL_KWARGS.merge(encounter_date: DATE_BEFORE_DD_MIN))
    assert_pre_call_refusal(**FULL_KWARGS.merge(encounter_date: DATE_AFTER_TODAY))
  end

  def test_refuses_program_or_appointment_with_outside_the_filed_sets_without_rpc
    assert_pre_call_refusal(**FULL_KWARGS.merge(program: "ADULT OUTPATIENT"))
    assert_pre_call_refusal(**FULL_KWARGS.merge(appointment_with: "SCHEDULED"))
  end

  def test_refuses_non_positive_integer_pointer_fields_without_rpc
    %i[clinic type_of_contact encounter_location community_of_service].each do |key|
      %w[0 -1 abc].each do |bad|
        assert_pre_call_refusal(**FULL_KWARGS.merge(key => bad), label: key)
      end
    end
  end

  def test_on_add_only_appointment_with_may_be_omitted_or_blank_on_the_wire
    wire = WIRE_ADD_REQUIRED_ONLY
    seed_add_success(wire, "8803", **REQUIRED_KWARGS)
    BH.save_visit(**REQUIRED_KWARGS.merge(appointment_with: nil))

    assert_equal wire, save_call[:params].first
  end

  def test_edit_refuses_each_explicit_field_when_nil_without_rpc
    EDIT_EXPLICIT_KEYS.each do |key|
      assert_pre_call_refusal(**FULL_KWARGS.merge(record_ien: RECORD_IEN, key => nil), label: key)
    end
  end

  def test_edit_allows_blank_appointment_with_to_clear_dot11_on_the_wire
    wire = WIRE_EDIT_NO_GROUP_CHANGE.sub("|#{APPOINTMENT_WITH}|", "||")
    kwargs = FULL_KWARGS.merge(record_ien: RECORD_IEN, appointment_with: "", group_name: "", group_time: nil, activity_time: nil)
    seed_edit_success(wire, RECORD_IEN, **kwargs)
    BH.save_visit(**kwargs)

    assert_equal wire, save_call[:params].first
  end

  def test_edit_allows_blank_group_name_to_mean_no_group_change_on_the_wire
    kwargs = FULL_KWARGS.merge(record_ien: RECORD_IEN, group_name: "", group_time: nil, activity_time: nil)
    seed_edit_success(WIRE_EDIT_NO_GROUP_CHANGE, RECORD_IEN, **kwargs)
    BH.save_visit(**kwargs)

    assert_equal WIRE_EDIT_NO_GROUP_CHANGE, save_call[:params].first
  end

  def test_edit_refuses_nil_group_name_without_rpc
    seed_edit_preconditions(RECORD_IEN)
    assert_pre_call_refusal(
      **FULL_KWARGS.merge(record_ien: RECORD_IEN, group_name: nil, group_time: nil, activity_time: nil),
      label: "group_name"
    )
  end

  def test_edit_with_non_empty_group_name_refuses_nil_group_time_or_activity_time_without_rpc
    seed_edit_preconditions(RECORD_IEN)
    assert_pre_call_refusal(
      **FULL_KWARGS.merge(record_ien: RECORD_IEN, group_time: nil), label: "group_time"
    )
    assert_pre_call_refusal(
      **FULL_KWARGS.merge(record_ien: RECORD_IEN, activity_time: nil), label: "activity_time"
    )
  end

  def test_refuses_group_name_longer_than_thirty_bytes_without_rpc
    assert_pre_call_refusal(**FULL_KWARGS.merge(group_name: "X" * 31))
    # 30 characters but 31 bytes under UTF-8 (ydb_chset=M $L semantics).
    assert_pre_call_refusal(**FULL_KWARGS.merge(group_name: "#{'a' * 29}é"))
  end

  def test_accepts_group_name_of_exactly_thirty_bytes_including_multibyte_characters
    name = "€" * 10 # 10 chars, 30 bytes in UTF-8
    assert_equal 30, name.bytesize
    pieces = WIRE_ADD_FULL.split("|", -1)
    pieces[12] = name
    wire = pieces.join("|")
    seed_add_success(wire, "8802", **FULL_KWARGS.merge(group_name: name))
    BH.save_visit(**FULL_KWARGS.merge(group_name: name))
    assert_equal wire, save_call[:params].first
  end

  def test_edit_refuses_when_pre_edit_patient_read_errors_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT, error: true)
    assert_pre_call_refusal(**FULL_KWARGS.merge(record_ien: RECORD_IEN), label: "pre-edit error")
    assert_empty amhg_calls
  end

  def test_edit_refuses_when_pre_edit_patient_read_is_empty_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, PATIENT, empty: true)
    assert_pre_call_refusal(**FULL_KWARGS.merge(record_ien: RECORD_IEN), label: "pre-edit empty")
    assert_empty amhg_calls
  end

  def test_edit_refuses_when_pre_edit_stored_patient_differs_without_amhg_rpc
    seed_pre_edit_patient(RECORD_IEN, OTHER_PATIENT)
    assert_pre_call_refusal(**FULL_KWARGS.merge(record_ien: RECORD_IEN), label: "pre-edit mismatch")
    assert_empty amhg_calls
  end

  def test_refuses_group_time_or_activity_time_when_group_name_is_blank_without_rpc
    assert_pre_call_refusal(**FULL_KWARGS.merge(group_name: "", group_time: GROUP_TIME))
    assert_pre_call_refusal(**FULL_KWARGS.merge(group_name: "   ", activity_time: ACTIVITY_TIME))
    assert_pre_call_refusal(**FULL_KWARGS.merge(group_name: nil, group_time: "10"))
  end

  def test_refuses_group_time_or_activity_time_outside_allowed_ranges_without_rpc
    %w[-1 10000 abc 12.5 9999.1].each do |bad|
      assert_pre_call_refusal(**FULL_KWARGS.merge(group_time: bad), label: "group_time=#{bad}")
      assert_pre_call_refusal(**FULL_KWARGS.merge(activity_time: bad), label: "activity_time=#{bad}")
    end
    assert_pre_call_refusal(**FULL_KWARGS.merge(activity_time: "0"), label: "activity_time=0")
  end

  def test_accepts_group_time_zero_and_activity_time_one_at_boundaries_without_rpc_refusal
    pieces = WIRE_ADD_FULL.split("|", -1)
    pieces[13] = "0"
    pieces[15] = "1"
    wire = pieces.join("|")
    seed_add_success(wire, "8802", **FULL_KWARGS.merge(group_time: "0", activity_time: "1"))
    BH.save_visit(**FULL_KWARGS.merge(group_time: "0", activity_time: "1"))
    assert_equal wire, save_call[:params].first
  end

  def test_accepts_activity_time_9999_with_group_name_without_rpc_refusal
    pieces = WIRE_ADD_FULL.split("|", -1)
    pieces[15] = "9999"
    wire = pieces.join("|")
    seed_add_success(wire, "8802", **FULL_KWARGS.merge(activity_time: "9999"))
    BH.save_visit(**FULL_KWARGS.merge(activity_time: "9999"))
    assert_equal wire, save_call[:params].first
  end

  def test_refuses_pipe_in_any_value_without_rpc
    FULL_KWARGS.each_key do |key|
      assert_pre_call_refusal(**FULL_KWARGS.merge(key => "a|b"), label: key)
    end
  end

  def test_refuses_caret_in_any_value_without_rpc
    FULL_KWARGS.each_key do |key|
      assert_pre_call_refusal(**FULL_KWARGS.merge(key => "bad^value"), label: key)
    end
  end

  def test_refuses_record_and_field_separators_and_control_characters_without_rpc
    toxic = [ "|", RS, US, "\x01", "\x7f", "ok\nbad", "^" ]
    toxic.each do |bad|
      assert_pre_call_refusal(**FULL_KWARGS.merge(group_name: bad))
    end
  end

  # --- post-call failures (AMHG returned; outcome unknown / read-back) -------

  def test_raises_when_reply_has_no_ien_row
    seed_post_amhg_trap(WIRE_ADD_FULL, **FULL_KWARGS) { seed_reply(WIRE_ADD_FULL, "#{RS}#{US}") }
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err)
  end

  def test_raises_when_reply_has_header_row_but_no_data_row
    seed_post_amhg_trap(WIRE_ADD_FULL, **FULL_KWARGS) { seed_reply(WIRE_ADD_FULL, "T00010BMXIEN#{RS}#{US}") }
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err)
  end

  def test_raises_when_reply_ien_is_zero
    seed_post_amhg_trap(WIRE_ADD_FULL, **FULL_KWARGS) { seed_success(WIRE_ADD_FULL, "0") }
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err)
  end

  def test_raises_when_reply_ien_is_blank_or_non_numeric
    seed_post_amhg_trap(WIRE_ADD_FULL, **FULL_KWARGS) { seed_success(WIRE_ADD_FULL, "") }
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err)
    seed_post_amhg_trap(WIRE_ADD_FULL, **FULL_KWARGS) { seed_success(WIRE_ADD_FULL, "abc") }
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err)
  end

  def test_raises_on_m_error_row
    seed_post_amhg_trap(WIRE_ADD_FULL, **FULL_KWARGS) { seed_reply(WIRE_ADD_FULL, "M ERROR|synthetic trap#{RS}#{US}") }
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err)
  end

  def test_parses_cia_sequence_echo_prefix_before_t00010bmxien_row
    body = "1\x00T00010BMXIEN#{RS}8802#{RS}#{US}"
    seed_post_amhg_trap(WIRE_ADD_FULL, **FULL_KWARGS) { seed_reply(WIRE_ADD_FULL, body) }
    seed_readback("8802,", **FULL_KWARGS)
    seed_provider_lister("8802", provider: PROVIDER, patient: PATIENT)
    assert_equal "8802", BH.save_visit(**FULL_KWARGS)
  end

  def test_edit_raises_when_returned_ien_differs_from_requested
    seed_pre_amhg_reads(**FULL_KWARGS)
    seed_provider_lister(RECORD_IEN, provider: PROVIDER, patient: PATIENT)
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_success(WIRE_EDIT_FULL, "9999")
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS, record_ien: RECORD_IEN) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
  end

  def test_raises_when_readback_ddr_errors_after_successful_looking_reply
    seed_add_post_amhg(WIRE_ADD_FULL, "8802", **FULL_KWARGS)
    seed_readback_error("8802,", **FULL_KWARGS)
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: "8802")
  end

  def test_raises_when_readback_ddr_returns_no_fields_after_successful_looking_reply
    seed_add_post_amhg(WIRE_ADD_FULL, "8802", **FULL_KWARGS)
    seed_readback_empty("8802,", **FULL_KWARGS)
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_not_confirmed(err, record_ien: "8802")
  end

  def test_raises_when_post_call_readback_ddr_raises_rpms_error
    seed_add_post_amhg(WIRE_ADD_FULL, "8802", **FULL_KWARGS)
    wrapper = RaiseOnBhVisitReadback.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err, record_ien: "8802")
    assert_kind_of RpmsRpc::Client::RpcMError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_raises_when_readback_dot01_mismatches
    seed_add_post_amhg(WIRE_ADD_FULL, "8802", **FULL_KWARGS, overrides: { ".01" => "3251031.9999" })
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_not_confirmed(err, record_ien: "8802")
  end

  def test_raises_when_readback_dot02_mismatches
    seed_add_post_amhg(WIRE_ADD_FULL, "8802", **FULL_KWARGS, overrides: { ".02" => "S" })
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_not_confirmed(err, record_ien: "8802")
  end

  def test_raises_when_readback_dot07_mismatches
    seed_add_post_amhg(WIRE_ADD_FULL, "8802", **FULL_KWARGS, overrides: { ".07" => "999" })
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_not_confirmed(err, record_ien: "8802")
  end

  def test_raises_when_readback_dot08_mismatches
    seed_add_post_amhg(WIRE_ADD_FULL, "8802", **FULL_KWARGS, overrides: { ".08" => OTHER_PATIENT })
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_not_confirmed(err, record_ien: "8802")
  end

  def test_raises_when_readback_dot04_mismatches
    seed_add_post_amhg(WIRE_ADD_FULL, "8802", **FULL_KWARGS, overrides: { ".04" => "999" })
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_not_confirmed(err, record_ien: "8802")
  end

  def test_raises_when_readback_dot05_mismatches
    seed_add_post_amhg(WIRE_ADD_FULL, "8802", **FULL_KWARGS, overrides: { ".05" => "999" })
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_not_confirmed(err, record_ien: "8802")
  end

  def test_raises_when_readback_dot11_mismatches
    seed_add_post_amhg(WIRE_ADD_FULL, "8802", **FULL_KWARGS, overrides: { ".11" => "U" })
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_not_confirmed(err, record_ien: "8802")
  end

  def test_raises_when_readback_dot25_mismatches
    seed_add_post_amhg(WIRE_ADD_FULL, "8802", **FULL_KWARGS, overrides: { ".25" => "999" })
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_not_confirmed(err, record_ien: "8802")
  end

  def test_raises_when_readback_group_field_mismatches
    seed_add_post_amhg(WIRE_ADD_FULL, "8802", **FULL_KWARGS, overrides: { "1109" => "OTHER GROUP" })
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_not_confirmed(err, record_ien: "8802")
  end

  def test_raises_when_post_call_provider_lookup_is_not_exactly_one_primary
    seed_add_success(WIRE_ADD_FULL, "8802", extra_primary: true, **FULL_KWARGS)
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_match(/may have been filed|outcome unknown/i, err.message)
  end

  def test_amhg_rpc_timeout_becomes_save_error_with_ambiguous_outcome
    seed_pre_amhg_reads(**FULL_KWARGS)
    wrapper = TimeoutOnAmhg.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err)
    assert_kind_of RpmsRpc::Client::RpcTimeoutError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_amhg_connection_error_becomes_save_error_with_ambiguous_outcome
    seed_pre_amhg_reads(**FULL_KWARGS)
    wrapper = ConnectionErrorOnAmhg.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err)
    assert_kind_of RpmsRpc::Client::ConnectionError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_amhg_rpc_m_error_becomes_save_error_with_ambiguous_outcome
    seed_pre_amhg_reads(**FULL_KWARGS)
    wrapper = RpcMErrorOnAmhg.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_amhg_reached
    assert_post_call_ambiguity(err)
    assert_kind_of RpmsRpc::Client::RpcMError, err.cause
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_amhg_rpc_not_available_error_is_not_wrapped
    seed_pre_amhg_reads(**FULL_KWARGS)
    wrapper = RpcNotAvailableOnAmhg.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    assert_raises(RpmsRpc::Client::RpcNotAvailableError) { BH.save_visit(**FULL_KWARGS) }
    assert_empty amhg_calls
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_amhg_rpc_refused_error_is_not_wrapped
    seed_pre_amhg_reads(**FULL_KWARGS)
    wrapper = RpcRefusedOnAmhg.new(@mock)
    RpmsRpc.configure { |c| c.client = wrapper }
    assert_raises(RpmsRpc::Client::RpcRefusedError) { BH.save_visit(**FULL_KWARGS) }
    assert_empty amhg_calls
  ensure
    RpmsRpc.configure { |c| c.client = @mock }
  end

  def test_error_message_does_not_echo_group_name_or_other_passed_values
    secret = "UNIQUE_PHI_MARKER_ISSUE536"
    seed_post_amhg_trap(WIRE_ADD_FULL, **FULL_KWARGS) { seed_success(WIRE_ADD_FULL.sub(GROUP_NAME, secret), "0") }
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS.merge(group_name: secret)) }
    assert_amhg_reached
    refute_includes err.message, secret
    refute_includes err.message, GROUP_NAME
    refute_includes err.message, PATIENT
    refute_includes err.message, PROGRAM
  end

  # --- registration ---------------------------------------------------------

  def test_retry_safety_classifies_save_visit_as_non_idempotent_write
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(BH, :save_visit)
  end

  def test_required_rpcs_lists_amhg_save_visit_under_behavioral_health
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    assert_includes doc.fetch("modules").fetch("RpmsRpc::BehavioralHealth"), RPC
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

  def ddr_lister_calls
    @mock.received_calls.select { |c| c[:rpc] == "DDR LISTER" }
  end

  def success_body(ien)
    "T00010BMXIEN#{RS}#{ien}#{RS}#{US}"
  end

  def seed_reply(wire_param, body)
    @mock.seed_text(:amhg_save_visit, wire_param, body)
  end

  def seed_success(wire_param, ien)
    seed_reply(wire_param, success_body(ien))
  end

  def ddr_gets_key(file:, iens:, fields:, flags:)
    Ddr.gets_entry_param(file: file, iens: iens, fields: fields, flags: flags).to_s
  end

  def program_internal(program)
    return "" if program.to_s.empty?

    {
      "MENTAL HEALTH" => "M",
      "SOCIAL SERVICES" => "S",
      "OTHER" => "O",
      "CHEMICAL DEPENDENCY" => "C"
    }.fetch(program)
  end

  def appointment_internal(appointment_with)
    return "" if appointment_with.to_s.empty?

    {
      "APPOINTMENT" => "A",
      "WALK-IN" => "W",
      "UNSPECIFIED" => "U"
    }.fetch(appointment_with)
  end

  def filed_encounter_internal(encounter_date)
    text = encounter_date.to_s
    return text unless text.include?(".")

    date, fraction = text.split(".", 2)
    fraction = fraction.sub(/0+\z/, "")
    fraction.empty? ? date : "#{date}.#{fraction}"
  end

  def readback_overrides_for(**kwargs)
    base = {
      ".01" => filed_encounter_internal(kwargs[:encounter_date]),
      ".02" => program_internal(kwargs[:program]),
      ".04" => kwargs[:encounter_location].to_s,
      ".05" => kwargs[:community_of_service].to_s,
      ".07" => kwargs[:type_of_contact].to_s,
      ".08" => kwargs[:patient].to_s,
      ".11" => appointment_internal(kwargs[:appointment_with]),
      ".25" => kwargs[:clinic].to_s
    }
    name = kwargs[:group_name].to_s.strip
    return base if name.empty?

    base.merge(
      ".12" => kwargs[:activity_time].to_s,
      ".34" => "1",
      "1104" => kwargs[:group_time].to_s,
      "1109" => name
    )
  end

  def readback_fields_for(**kwargs)
    kwargs[:group_name].to_s.strip.empty? ? READBACK_FIELDS : READBACK_FIELDS_GROUP
  end

  def provider_lister_key(visit_ien)
    Ddr.lister_param(
      file: PROVIDER_FILE, xref: PROVIDER_LOOKUP_XREF, part: visit_ien.to_s,
      from: PROVIDER_LOOKUP_FROM, screen: provider_lookup_screen(visit_ien),
      fields: PROVIDER_LOOKUP_FIELDS, flags: PROVIDER_LOOKUP_FLAGS, max: PROVIDER_LOOKUP_MAX
    ).to_s
  end

  # Until save_visit pins the SCREEN lister call, the broker still issues PART-only LISTER.
  def provider_lister_key_legacy(visit_ien)
    Ddr.lister_param(
      file: PROVIDER_FILE, xref: PROVIDER_LOOKUP_XREF, part: visit_ien.to_s,
      fields: PROVIDER_LOOKUP_FIELDS, flags: PROVIDER_LOOKUP_FLAGS, max: PROVIDER_LOOKUP_MAX
    ).to_s
  end

  def provider_lookup_screen(visit_ien)
    "I $P(^(0),U,3)=#{visit_ien}"
  end

  def pointer_ddr_expectations(**kwargs)
    [
      { file: CLINIC_FILE, iens: "#{kwargs.fetch(:clinic)},", label: "clinic" },
      { file: TYPE_OF_CONTACT_FILE, iens: "#{kwargs.fetch(:type_of_contact)},", label: "type of contact" },
      { file: ENCOUNTER_LOCATION_FILE, iens: "#{kwargs.fetch(:encounter_location)},", label: "encounter location" },
      { file: COMMUNITY_FILE, iens: "#{kwargs.fetch(:community_of_service)},", label: "community of service" },
      { file: PROVIDER_DUZ_FILE, iens: "#{kwargs.fetch(:provider)},", label: "provider" }
    ]
  end

  def seed_pointer_exists(file, ien, blank_dot01: false)
    key = ddr_gets_key(
      file: file, iens: "#{ien},", fields: PRE_POINTER_FIELDS, flags: PRE_POINTER_FLAGS
    )
    dot01 = blank_dot01 ? "" : "SYNTH,POINTER"
    body = "[Data]\n#{file}^#{ien}^.01^#{dot01}^POINTER"
    @mock.seed(:ddr_gets_entry_data, key, body)
  end

  def seed_pointer_reads(**kwargs)
    seed_pointer_exists(CLINIC_FILE, kwargs.fetch(:clinic, CLINIC))
    seed_pointer_exists(TYPE_OF_CONTACT_FILE, kwargs.fetch(:type_of_contact, TYPE_OF_CONTACT))
    seed_pointer_exists(ENCOUNTER_LOCATION_FILE, kwargs.fetch(:encounter_location, ENCOUNTER_LOCATION))
    seed_pointer_exists(COMMUNITY_FILE, kwargs.fetch(:community_of_service, COMMUNITY_OF_SERVICE))
    seed_pointer_exists(PROVIDER_DUZ_FILE, kwargs.fetch(:provider, PROVIDER))
  end

  def seed_pre_amhg_reads(**kwargs)
    seed_patient_exists(kwargs.fetch(:patient, PATIENT))
    seed_pointer_reads(**kwargs)
  end

  def seed_post_amhg_trap(_wire, **kwargs)
    seed_pre_amhg_reads(**kwargs)
    yield
  end

  def provider_lister_body(provider:, patient:, visit_ien:, extra_primary: false, foreign_visit_row: false,
                           more: false, error: false)
    return "[Errors]" if error

    rows = [ [ provider.to_s, patient.to_s, visit_ien.to_s, "P" ] ]
    rows << [ "888", patient.to_s, visit_ien.to_s, "P" ] if extra_primary
    rows << [ "777", patient.to_s, "88888", "P" ] if foreign_visit_row
    lines = rows.each_with_index.map { |pieces, i| "#{i + 1}^#{pieces.join('^')}" }
    body = "[Data]\n#{lines.join("\n")}"
    more ? "[Misc]\nMORE^1^1\n#{body}" : body
  end

  def seed_provider_lister(visit_ien, provider:, patient:, extra_primary: false, foreign_visit_row: false,
                           more: false, error: false)
    body = provider_lister_body(
      provider: provider, patient: patient, visit_ien: visit_ien, extra_primary: extra_primary,
      foreign_visit_row: foreign_visit_row, more: more, error: error
    )
    @mock.seed(:ddr_lister, provider_lister_key(visit_ien), body)
    @mock.seed(:ddr_lister, provider_lister_key_legacy(visit_ien), body)
  end

  def seed_patient_exists(dfn, error: false, empty: false, blank_dot01: false)
    key = ddr_gets_key(
      file: PATIENT_FILE, iens: "#{dfn},",
      fields: PRE_ADD_PATIENT_FIELDS, flags: PRE_ADD_PATIENT_FLAGS
    )
    body =
      if error
        "[ERROR]"
      elsif empty
        "[Data]"
      elsif blank_dot01
        "[Data]\n#{PATIENT_FILE}^#{dfn}^.01^^"
      else
        "[Data]\n#{PATIENT_FILE}^#{dfn}^.01^SYNTH,PATIENT^PATIENT,SYNTH"
      end
    @mock.seed(:ddr_gets_entry_data, key, body)
  end

  def seed_edit_preconditions(ien, patient: PATIENT, provider: PROVIDER, signed: false, **kwargs)
    seed_pre_amhg_reads(**FULL_KWARGS.merge(kwargs).merge(patient: patient, provider: provider))
    seed_provider_lister(ien, provider: provider, patient: patient)
    seed_pre_edit_patient(ien, patient, signed: signed)
  end

  def seed_readback(iens, **kwargs)
    overrides = kwargs.delete(:overrides) || {}
    fields_map = readback_overrides_for(**kwargs).merge(overrides)
    ien_bare = iens.delete_suffix(",")
    lines = fields_map.map do |field, internal|
      "#{BH_VISIT_FILE}^#{ien_bare}^#{field}^#{internal}^EXT"
    end
    readback_field_lists_for(**kwargs).each do |field_list|
      filtered = lines.select { |line| field_list.split(";").include?(line.split("^")[2]) }
      key = ddr_gets_key(
        file: BH_VISIT_FILE, iens: iens, fields: field_list, flags: READBACK_FLAGS
      )
      @mock.seed(:ddr_gets_entry_data, key, "[Data]\n#{filtered.join("\n")}")
    end
  end

  def readback_field_lists_for(**kwargs)
    pinned = readback_fields_for(**kwargs)
    lists = [ READBACK_FIELDS, pinned ]
    lists.uniq
  end

  def seed_readback_error(iens, **kwargs)
    readback_field_lists_for(**kwargs).each do |field_list|
      key = ddr_gets_key(
        file: BH_VISIT_FILE, iens: iens, fields: field_list, flags: READBACK_FLAGS
      )
      @mock.seed(:ddr_gets_entry_data, key, "[ERROR]")
    end
  end

  def seed_readback_empty(iens, **kwargs)
    readback_field_lists_for(**kwargs).each do |field_list|
      key = ddr_gets_key(
        file: BH_VISIT_FILE, iens: iens, fields: field_list, flags: READBACK_FLAGS
      )
      @mock.seed(:ddr_gets_entry_data, key, "[Data]")
    end
  end

  def seed_pre_edit_patient(ien, patient, error: false, empty: false, signed: false)
    key = ddr_gets_key(
      file: BH_VISIT_FILE,
      iens: "#{ien},",
      fields: PRE_EDIT_VISIT_FIELDS,
      flags: PRE_EDIT_VISIT_FLAGS
    )
    legacy_key = ddr_gets_key(
      file: BH_VISIT_FILE, iens: "#{ien},", fields: ".08", flags: PRE_EDIT_VISIT_FLAGS
    )
    body =
      if error
        "[ERROR]"
      elsif empty
        "[Data]"
      else
        signed_at = signed ? "3251031.12" : ""
        "[Data]\n" \
          "#{BH_VISIT_FILE}^#{ien}^.08^#{patient}^PATIENT,SYNTH\n" \
          "#{BH_VISIT_FILE}^#{ien}^1112^#{signed_at}^SIGNED"
      end
    @mock.seed(:ddr_gets_entry_data, key, body)
    return if error || empty

    legacy_body = "[Data]\n#{BH_VISIT_FILE}^#{ien}^.08^#{patient}^PATIENT,SYNTH"
    @mock.seed(:ddr_gets_entry_data, legacy_key, legacy_body)
  end

  def seed_add_post_amhg(wire, ien, **readback_kwargs)
    overrides = readback_kwargs.delete(:overrides)
    seed_pre_amhg_reads(**readback_kwargs)
    seed_success(wire, ien)
    seed_readback("#{ien},", **readback_kwargs, overrides: overrides)
  end

  def seed_add_success(wire, ien, extra_primary: false, **readback_kwargs)
    opts = readback_kwargs.dup
    foreign = opts.delete(:foreign_visit_row)
    seed_pre_amhg_reads(**opts)
    seed_success(wire, ien)
    seed_readback("#{ien},", **readback_kwargs)
    seed_provider_lister(
      ien,
      provider: readback_kwargs.fetch(:provider, PROVIDER),
      patient: readback_kwargs.fetch(:patient, PATIENT),
      extra_primary: extra_primary,
      foreign_visit_row: foreign == true
    )
  end

  def seed_edit_success(wire, ien, **readback_kwargs)
    opts = readback_kwargs.dup
    foreign = opts.delete(:foreign_visit_row)
    patient = readback_kwargs.fetch(:patient, PATIENT)
    provider = readback_kwargs.fetch(:provider, PROVIDER)
    seed_pre_amhg_reads(**readback_kwargs)
    seed_provider_lister(
      ien, provider: provider, patient: patient, foreign_visit_row: foreign == true
    )
    seed_pre_edit_patient(ien, patient)
    seed_success(wire, ien)
    seed_readback("#{ien},", **readback_kwargs)
    seed_provider_lister(
      ien, provider: provider, patient: patient, foreign_visit_row: foreign == true
    )
  end

  def assert_readback_ddr_call(iens, **kwargs)
    fields = readback_fields_for(**kwargs)
    call = ddr_gets_calls.find do |c|
      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["IENS"] == iens && p["FIELDS"] == fields
    end
    refute_nil call, "expected read-back DDR GETS for #{iens} fields #{fields}"
  end

  def assert_pre_edit_ddr_call(iens)
    call = ddr_gets_calls.find do |c|
      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["IENS"] == iens && p["FIELDS"] == PRE_EDIT_VISIT_FIELDS
    end
    refute_nil call, "expected pre-edit visit DDR GETS for #{iens}"
  end

  def assert_amhg_reached
    refute_empty amhg_calls, "expected AMHG SAVE VISIT before post-call SaveError"
  end

  def assert_pre_call_refusal(label: nil, **kwargs)
    err = assert_raises(BH::SaveError, label) { BH.save_visit(**kwargs) }
    assert_empty amhg_calls, "pre-call refusal must not RPC#{label ? " (#{label})" : ""}"
    err
  end

  def assert_post_call_ambiguity(err, record_ien: nil)
    assert_match(/may have been filed|outcome unknown/i, err.message)
    refute_includes err.message, PATIENT
    refute_includes err.message, PROGRAM
    refute_includes err.message, GROUP_NAME
    return unless record_ien

    assert_includes err.message, record_ien
  end

  def assert_not_confirmed(err, record_ien:)
    assert_match(/not confirmed|may have been filed/i, err.message)
    assert_includes err.message, record_ien
    refute_includes err.message, PATIENT
    refute_includes err.message, PROGRAM
  end
end

# Raises RpcTimeoutError on AMHG SAVE VISIT so save_visit must map it to SaveError.
class TimeoutOnAmhg < SimpleDelegator
  def call_rpc_global_array(rpc_name, *params)
    if rpc_name == "AMHG SAVE VISIT"
      super
      raise RpmsRpc::Client::RpcTimeoutError, "AMHG SAVE VISIT timed out (synthetic)"
    end

    super
  end
end

class ConnectionErrorOnAmhg < SimpleDelegator
  def call_rpc_global_array(rpc_name, *params)
    if rpc_name == "AMHG SAVE VISIT"
      super
      raise RpmsRpc::Client::ConnectionError, "AMHG SAVE VISIT connection lost (synthetic)"
    end

    super
  end
end

class RpcMErrorOnAmhg < SimpleDelegator
  def call_rpc_global_array(rpc_name, *params)
    if rpc_name == "AMHG SAVE VISIT"
      super
      raise RpmsRpc::Client::RpcMError, "AMHG SAVE VISIT M error (synthetic)"
    end

    super
  end
end

class RpcNotAvailableOnAmhg < SimpleDelegator
  def call_rpc_global_array(rpc_name, *_params)
    raise RpmsRpc::Client::RpcNotAvailableError, "AMHG SAVE VISIT not registered (synthetic)" if rpc_name == "AMHG SAVE VISIT"

    super
  end
end

class RpcRefusedOnAmhg < SimpleDelegator
  def call_rpc_global_array(rpc_name, *_params)
    raise RpmsRpc::Client::RpcRefusedError, "AMHG SAVE VISIT refused (synthetic)" if rpc_name == "AMHG SAVE VISIT"

    super
  end
end

class RaiseOnBhVisitReadback < SimpleDelegator
  def call_rpc_global_array(rpc_name, *params)
    if rpc_name == "DDR GETS ENTRY DATA"
      file = params.first.is_a?(Hash) ? params.first["FILE"] : nil
      raise RpmsRpc::Client::RpcMError, "read-back failed (synthetic)" if file == "9002011"
    end

    super
  end
end
