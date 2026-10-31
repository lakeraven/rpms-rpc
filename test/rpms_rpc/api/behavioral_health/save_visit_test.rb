# frozen_string_literal: true

require "minitest/autorun"
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
  # Pinned: save_visit must use these for post-call confirmation read-back.
  READBACK_FIELDS = ".01;.02;.04;.05;.07;.08;.11;.25"
  READBACK_FLAGS = "IE"
  # Pinned: save_visit must read stored patient (.08) before an edit RPC.
  PRE_EDIT_PATIENT_FIELDS = ".08"
  PRE_EDIT_PATIENT_FLAGS = "I"

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
    program clinic type_of_contact encounter_location community_of_service appointment_with
  ].freeze

  # VISIT^AMHGSVF: 16 pieces. Piece 7 (ARR) blank; piece 15 (e-sign) always blank.
  WIRE_ADD_FULL =
    "A||#{PROVIDER}|#{PROGRAM}|#{CLINIC}|#{TYPE_OF_CONTACT}||#{ENCOUNTER}|#{ENCOUNTER_LOCATION}|" \
    "#{APPOINTMENT_WITH}|#{COMMUNITY_OF_SERVICE}|#{PATIENT}|#{GROUP_NAME}|#{GROUP_TIME}||#{ACTIVITY_TIME}".freeze

  WIRE_ADD_REQUIRED_ONLY =
    "A||#{PROVIDER}|||||#{ENCOUNTER.split('.').first}||||#{PATIENT}||||".freeze

  WIRE_EDIT_FULL =
    "E|#{RECORD_IEN}|#{PROVIDER}|#{PROGRAM}|#{CLINIC}|#{TYPE_OF_CONTACT}||#{ENCOUNTER}|#{ENCOUNTER_LOCATION}|" \
    "#{APPOINTMENT_WITH}|#{COMMUNITY_OF_SERVICE}|#{PATIENT}|#{GROUP_NAME}|#{GROUP_TIME}||#{ACTIVITY_TIME}".freeze

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
    patient: PATIENT
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
    assert_readback_ddr_call("8802,")
  end

  def test_edit_success_returns_the_requested_record_ien_after_pre_edit_check_and_readback
    seed_edit_success(WIRE_EDIT_FULL, RECORD_IEN, **FULL_KWARGS)
    assert_equal RECORD_IEN, BH.save_visit(**FULL_KWARGS, record_ien: RECORD_IEN)
    assert_pre_edit_ddr_call("#{RECORD_IEN},")
    assert_readback_ddr_call("#{RECORD_IEN},")
  end

  def test_success_pins_ddr_gets_readback_fields_and_flags
    seed_add_success(WIRE_ADD_FULL, "8802", **FULL_KWARGS)
    BH.save_visit(**FULL_KWARGS)

    param = ddr_gets_calls.last[:params].first
    assert_equal READBACK_FIELDS, param["FIELDS"]
    assert_equal READBACK_FLAGS, param["FLAGS"]
    assert_equal BH_VISIT_FILE, param["FILE"]
  end

  def test_edit_pins_pre_edit_patient_ddr_gets_fields_and_flags
    seed_edit_success(WIRE_EDIT_FULL, RECORD_IEN, **FULL_KWARGS)
    BH.save_visit(**FULL_KWARGS, record_ien: RECORD_IEN)

    param = ddr_gets_calls.first[:params].first
    assert_equal PRE_EDIT_PATIENT_FIELDS, param["FIELDS"]
    assert_equal PRE_EDIT_PATIENT_FLAGS, param["FLAGS"]
    assert_equal "#{RECORD_IEN},", param["IENS"]
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
    %w[yesterday 2026-10-31 326101 12345678].each do |bad|
      assert_pre_call_refusal(**FULL_KWARGS.merge(encounter_date: bad))
    end
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

  def test_on_add_nil_optional_fields_still_mean_blank_on_the_wire
    seed_add_success(WIRE_ADD_REQUIRED_ONLY, "8803", **REQUIRED_KWARGS)
    BH.save_visit(**REQUIRED_KWARGS.merge(program: nil, clinic: nil))

    assert_equal WIRE_ADD_REQUIRED_ONLY, save_call[:params].first
  end

  def test_edit_refuses_each_explicit_field_when_nil_without_rpc
    EDIT_EXPLICIT_KEYS.each do |key|
      assert_pre_call_refusal(**FULL_KWARGS.merge(record_ien: RECORD_IEN, key => nil), label: key)
    end
  end

  def test_edit_allows_blank_string_to_clear_filed_pieces_on_the_wire
    wire = WIRE_EDIT_FULL.sub("|#{PROGRAM}|", "||").sub("|#{CLINIC}|", "||")
    kwargs = FULL_KWARGS.merge(record_ien: RECORD_IEN, program: "", clinic: "")
    seed_edit_success(wire, RECORD_IEN, **kwargs)
    BH.save_visit(**kwargs)

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

  def test_refuses_group_time_or_activity_time_outside_zero_through_9999_without_rpc
    %w[-1 10000 abc 12.5 9999.1].each do |bad|
      assert_pre_call_refusal(**FULL_KWARGS.merge(group_time: bad), label: "group_time=#{bad}")
      assert_pre_call_refusal(**FULL_KWARGS.merge(activity_time: bad), label: "activity_time=#{bad}")
    end
  end

  def test_accepts_group_time_and_activity_time_at_boundaries_without_rpc_refusal
    pieces = WIRE_ADD_FULL.split("|", -1)
    pieces[13] = "0"
    pieces[15] = "9999"
    wire = pieces.join("|")
    seed_add_success(wire, "8802", **FULL_KWARGS.merge(group_time: "0", activity_time: "9999"))
    BH.save_visit(**FULL_KWARGS.merge(group_time: "0", activity_time: "9999"))
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
    seed_reply(WIRE_ADD_FULL, "#{RS}#{US}")
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_post_call_ambiguity(err)
  end

  def test_raises_when_reply_has_header_row_but_no_data_row
    seed_reply(WIRE_ADD_FULL, "T00010BMXIEN#{RS}#{US}")
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_post_call_ambiguity(err)
  end

  def test_raises_when_reply_ien_is_zero
    seed_success(WIRE_ADD_FULL, "0")
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_post_call_ambiguity(err)
  end

  def test_raises_when_reply_ien_is_blank_or_non_numeric
    seed_success(WIRE_ADD_FULL, "")
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_post_call_ambiguity(err)
    seed_success(WIRE_ADD_FULL, "abc")
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_post_call_ambiguity(err)
  end

  def test_raises_on_m_error_row
    seed_reply(WIRE_ADD_FULL, "M ERROR|synthetic trap#{RS}#{US}")
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_post_call_ambiguity(err)
  end

  def test_edit_raises_when_returned_ien_differs_from_requested
    seed_pre_edit_patient(RECORD_IEN, PATIENT)
    seed_success(WIRE_EDIT_FULL, "9999")
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS, record_ien: RECORD_IEN) }
    assert_post_call_ambiguity(err, record_ien: RECORD_IEN)
  end

  def test_raises_when_readback_ddr_errors_after_successful_looking_reply
    seed_success(WIRE_ADD_FULL, "8802")
    seed_readback_error("8802,")
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_not_confirmed(err, record_ien: "8802")
  end

  def test_raises_when_readback_ddr_returns_no_fields_after_successful_looking_reply
    seed_success(WIRE_ADD_FULL, "8802")
    seed_readback_empty("8802,")
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_not_confirmed(err, record_ien: "8802")
  end

  def test_raises_when_readback_dot01_mismatches
    seed_success(WIRE_ADD_FULL, "8802")
    seed_readback("8802,", **FULL_KWARGS, overrides: { ".01" => "3251031.9999" })
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_not_confirmed(err, record_ien: "8802")
  end

  def test_raises_when_readback_dot02_mismatches
    seed_success(WIRE_ADD_FULL, "8802")
    seed_readback("8802,", **FULL_KWARGS, overrides: { ".02" => "S" })
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_not_confirmed(err, record_ien: "8802")
  end

  def test_raises_when_readback_dot07_mismatches
    seed_success(WIRE_ADD_FULL, "8802")
    seed_readback("8802,", **FULL_KWARGS, overrides: { ".07" => "999" })
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_not_confirmed(err, record_ien: "8802")
  end

  def test_raises_when_readback_dot08_mismatches
    seed_success(WIRE_ADD_FULL, "8802")
    seed_readback("8802,", **FULL_KWARGS, overrides: { ".08" => OTHER_PATIENT })
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_not_confirmed(err, record_ien: "8802")
  end

  def test_error_message_does_not_echo_group_name_or_other_passed_values
    secret = "UNIQUE_PHI_MARKER_ISSUE536"
    seed_success(WIRE_ADD_FULL.sub(GROUP_NAME, secret), "0")
    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS.merge(group_name: secret)) }
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

  def save_call
    @mock.received_calls.find { |c| c[:rpc] == RPC }
  end

  def amhg_calls
    @mock.received_calls.select { |c| c[:rpc] == RPC }
  end

  def ddr_gets_calls
    @mock.received_calls.select { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
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
    {
      ".01" => filed_encounter_internal(kwargs[:encounter_date]),
      ".02" => program_internal(kwargs[:program]),
      ".04" => kwargs[:encounter_location].to_s,
      ".05" => kwargs[:community_of_service].to_s,
      ".07" => kwargs[:type_of_contact].to_s,
      ".08" => kwargs[:patient].to_s,
      ".11" => appointment_internal(kwargs[:appointment_with]),
      ".25" => kwargs[:clinic].to_s
    }
  end

  def seed_readback(iens, **kwargs)
    overrides = kwargs.delete(:overrides) || {}
    fields = readback_overrides_for(**kwargs).merge(overrides)
    ien_bare = iens.delete_suffix(",")
    lines = fields.map do |field, internal|
      "#{BH_VISIT_FILE}^#{ien_bare}^#{field}^#{internal}^EXT"
    end
    key = ddr_gets_key(
      file: BH_VISIT_FILE, iens: iens, fields: READBACK_FIELDS, flags: READBACK_FLAGS
    )
    @mock.seed(:ddr_gets_entry_data, key, "[Data]\n#{lines.join("\n")}")
  end

  def seed_readback_error(iens)
    key = ddr_gets_key(
      file: BH_VISIT_FILE, iens: iens, fields: READBACK_FIELDS, flags: READBACK_FLAGS
    )
    @mock.seed(:ddr_gets_entry_data, key, "[ERROR]")
  end

  def seed_readback_empty(iens)
    key = ddr_gets_key(
      file: BH_VISIT_FILE, iens: iens, fields: READBACK_FIELDS, flags: READBACK_FLAGS
    )
    @mock.seed(:ddr_gets_entry_data, key, "[Data]")
  end

  def seed_pre_edit_patient(ien, patient, error: false, empty: false)
    key = ddr_gets_key(
      file: BH_VISIT_FILE,
      iens: "#{ien},",
      fields: PRE_EDIT_PATIENT_FIELDS,
      flags: PRE_EDIT_PATIENT_FLAGS
    )
    body =
      if error
        "[ERROR]"
      elsif empty
        "[Data]"
      else
        "[Data]\n#{BH_VISIT_FILE}^#{ien}^.08^#{patient}^PATIENT,SYNTH"
      end
    @mock.seed(:ddr_gets_entry_data, key, body)
  end

  def seed_add_success(wire, ien, **readback_kwargs)
    seed_success(wire, ien)
    seed_readback("#{ien},", **readback_kwargs)
  end

  def seed_edit_success(wire, ien, **readback_kwargs)
    seed_pre_edit_patient(ien, readback_kwargs.fetch(:patient))
    seed_success(wire, ien)
    seed_readback("#{ien},", **readback_kwargs)
  end

  def assert_readback_ddr_call(iens)
    call = ddr_gets_calls.find do |c|
      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["IENS"] == iens && p["FIELDS"] == READBACK_FIELDS
    end
    refute_nil call, "expected read-back DDR GETS for #{iens}"
  end

  def assert_pre_edit_ddr_call(iens)
    call = ddr_gets_calls.find do |c|
      p = c[:params].first
      p["FILE"] == BH_VISIT_FILE && p["IENS"] == iens && p["FIELDS"] == PRE_EDIT_PATIENT_FIELDS
    end
    refute_nil call, "expected pre-edit patient DDR GETS for #{iens}"
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
