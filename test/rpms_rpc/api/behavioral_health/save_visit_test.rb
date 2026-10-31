# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/mappings"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/retry_safety"

# AMHG SAVE VISIT — VISIT^AMHGSVF (AMHGSVF.m), MODV^AMHGEVF (AMHGEVF.m).
# Mock seeds use mapping :amhg_save_visit → RPC "AMHG SAVE VISIT".
# One pipe-delimited AMHSTR; reply is GLOBAL ARRAY with T00010BMXIEN row then IEN.
class BehavioralHealthSaveVisitTest < Minitest::Test
  BH = RpmsRpc::BehavioralHealth
  RPC = "AMHG SAVE VISIT"
  RS = "\x1e" # $C(30)
  US = "\x1f" # $C(31)

  ROOT = File.expand_path("../../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  PATIENT = "990536"
  PROVIDER = "412"
  RECORD_IEN = "8801"
  ENCOUNTER = "3251031.0930"
  PROGRAM = "MENTAL HEALTH"
  CLINIC = "17"
  TYPE_OF_CONTACT = "3"
  ENCOUNTER_LOCATION = "55"
  COMMUNITY_OF_SERVICE = "42"
  APPOINTMENT_WITH = "APPOINTMENT"
  GROUP_NAME = "SYNTH GROUP ALPHA"
  GROUP_TIME = "45"
  ACTIVITY_TIME = "30"

  # VISIT^AMHGSVF: 16 pieces. Piece 7 (ARR) is always blank — MODV^AMHGEVF never files it.
  WIRE_ADD_FULL =
    "A||#{PROVIDER}|#{PROGRAM}|#{CLINIC}|#{TYPE_OF_CONTACT}||#{ENCOUNTER}|#{ENCOUNTER_LOCATION}|" \
    "#{APPOINTMENT_WITH}|#{COMMUNITY_OF_SERVICE}|#{PATIENT}|#{GROUP_NAME}|#{GROUP_TIME}|1|#{ACTIVITY_TIME}".freeze

  WIRE_ADD_REQUIRED_ONLY =
    "A||#{PROVIDER}||||#{ENCOUNTER.split('.').first}||||#{PATIENT}||||".freeze

  WIRE_EDIT_FULL =
    "E|#{RECORD_IEN}|#{PROVIDER}|#{PROGRAM}|#{CLINIC}|#{TYPE_OF_CONTACT}||#{ENCOUNTER}|#{ENCOUNTER_LOCATION}|" \
    "#{APPOINTMENT_WITH}|#{COMMUNITY_OF_SERVICE}|#{PATIENT}|#{GROUP_NAME}|#{GROUP_TIME}|1|#{ACTIVITY_TIME}".freeze

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
    activity_time: ACTIVITY_TIME,
    esign: true
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
    seed_success(WIRE_ADD_FULL, "8802")
    BH.save_visit(**FULL_KWARGS)

    call = save_call
    refute_nil call, "expected #{RPC}"
    assert_equal 1, call[:params].length,
                 "AMH rejects multi-actual calls with YDB-E-ACTLSTTOOLONG (#198)"
    assert_equal WIRE_ADD_FULL, call[:params].first
    assert_equal RPC, call[:rpc]
  end

  def test_add_pins_required_fields_only_with_blank_optional_pieces
    seed_success(WIRE_ADD_REQUIRED_ONLY, "8803")
    BH.save_visit(**REQUIRED_KWARGS)

    assert_equal WIRE_ADD_REQUIRED_ONLY, save_call[:params].first
  end

  def test_edit_pins_the_exact_sixteen_piece_wire_string
    seed_success(WIRE_EDIT_FULL, RECORD_IEN)
    BH.save_visit(**FULL_KWARGS, record_ien: RECORD_IEN)

    assert_equal WIRE_EDIT_FULL, save_call[:params].first
  end

  def test_save_visit_runs_under_amhgrpc_and_restores_the_callers_context
    seed_success(WIRE_ADD_FULL, "8802")
    caller_context = @mock.current_context

    BH.save_visit(**FULL_KWARGS)

    call = save_call
    assert_equal "AMHGRPC", call[:context]
    assert_equal caller_context, @mock.current_context
    assert_equal [ "AMHGRPC", caller_context ], @mock.context_binds
  end

  def test_add_success_returns_the_record_ien_from_the_t00010bmxien_row
    seed_success(WIRE_ADD_FULL, "8802")
    assert_equal "8802", BH.save_visit(**FULL_KWARGS)
  end

  def test_edit_success_returns_the_requested_record_ien
    seed_success(WIRE_EDIT_FULL, RECORD_IEN)
    assert_equal RECORD_IEN, BH.save_visit(**FULL_KWARGS, record_ien: RECORD_IEN)
  end

  def test_esign_false_sends_blank_piece_fifteen
    wire = WIRE_ADD_FULL.sub("|1|#{ACTIVITY_TIME}", "||#{ACTIVITY_TIME}")
    seed_success(wire, "8802")
    BH.save_visit(**FULL_KWARGS.merge(esign: false))

    assert_equal wire, save_call[:params].first
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
    # MODV^AMHGEVF: mode E with blank IEN silently becomes add — never send that.
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

  def test_refuses_group_time_or_activity_time_when_group_name_is_blank_without_rpc
    assert_pre_call_refusal(**FULL_KWARGS.merge(group_name: "", group_time: GROUP_TIME))
    assert_pre_call_refusal(**FULL_KWARGS.merge(group_name: "   ", activity_time: ACTIVITY_TIME))
    assert_pre_call_refusal(**FULL_KWARGS.merge(group_name: nil, group_time: "10"))
  end

  def test_refuses_pipe_in_any_value_without_rpc
    FULL_KWARGS.each_key do |key|
      next if key == :esign

      assert_pre_call_refusal(**FULL_KWARGS.merge(key => "a|b"), label: key)
    end
  end

  def test_refuses_record_and_field_separators_and_control_characters_without_rpc
    toxic = [ "|", RS, US, "\x01", "\x7f", "ok\nbad" ]
    toxic.each do |bad|
      assert_pre_call_refusal(**FULL_KWARGS.merge(group_name: bad))
    end
  end

  # --- post-call failures ---------------------------------------------------

  def test_raises_when_reply_has_no_ien_row
    seed_reply(WIRE_ADD_FULL, "#{RS}#{US}")
    assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
  end

  def test_raises_when_reply_has_header_row_but_no_data_row
    seed_reply(WIRE_ADD_FULL, "T00010BMXIEN#{RS}#{US}")
    assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
  end

  def test_raises_when_reply_ien_is_zero
    seed_success(WIRE_ADD_FULL, "0")
    assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
  end

  def test_raises_when_reply_ien_is_blank_or_non_numeric
    seed_success(WIRE_ADD_FULL, "")
    assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    seed_success(WIRE_ADD_FULL, "abc")
    assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
  end

  def test_raises_on_m_error_row
    seed_reply(WIRE_ADD_FULL, "M ERROR|synthetic trap#{RS}#{US}")
    assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
  end

  def test_edit_raises_when_returned_ien_differs_from_requested
    seed_success(WIRE_EDIT_FULL, "9999")
    assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS, record_ien: RECORD_IEN) }
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

  def success_body(ien)
    "T00010BMXIEN#{RS}#{ien}#{RS}#{US}"
  end

  def seed_reply(wire_param, body)
    @mock.seed_text(:amhg_save_visit, wire_param, body)
  end

  def seed_success(wire_param, ien)
    seed_reply(wire_param, success_body(ien))
  end

  def assert_pre_call_refusal(label: nil, **kwargs)
    err = assert_raises(BH::SaveError, label) { BH.save_visit(**kwargs) }
    assert_empty @mock.received_calls, "pre-call refusal must not RPC#{label ? " (#{label})" : ""}"
    err
  end
end
