# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require "rpms_rpc/mappings"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/retry_safety"
require_relative "amhg_replay"

# AMHG SAVE VISIT: VISIT^AMHGSVF (AMHGSVF.m), MODV^AMHGEVF (AMHGEVF.m).
#
# The guard and refusal cases, read from the conversations the pinned build
# had with BehavioralHealth.save_visit (test/fixtures/captured_replies/amhg-save-visit.yml)
# for synthetic patient DFN 990036: an add with every field and a group, an
# add with the required fields only, an edit with a group and one with no
# group change, and the refusals the build's replies lead to (a clinic or a
# patient not on file, an edit naming another patient, a provider who is not
# the visit's primary, a record not on file). The round trip itself is proven
# by test/live/behavioral_health_save_visit_live_test.rb (rpms-rpc#622, option b).
#
# The after-today guard reads the server's today from ORWU DT "T"
# (save_visit_server_today_test.rb); each flow starts with that read.
class BehavioralHealthSaveVisitTest < Minitest::Test
  BH = RpmsRpc::BehavioralHealth
  SLUG = "amhg-save-visit"
  RPC = "AMHG SAVE VISIT"
  GETS = "DDR GETS ENTRY DATA"
  LISTER = "DDR LISTER"
  ORWU_DT = "ORWU DT"
  CLINIC_FILE = "40.7"

  ROOT = File.expand_path("../../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  def self.wire(flow) = CapturedReplies.flow(SLUG, flow).find { |c| c["rpc"] == RPC }.fetch("inputs").first

  WIRE_ADD = wire("add")
  WIRE_ADD_REQUIRED = wire("add_required")
  WIRE_EDIT = wire("edit")
  WIRE_EDIT_NO_GROUP = wire("edit_no_group_change")
  _, _, PROVIDER, PROGRAM, CLINIC, TYPE_OF_CONTACT, _, ENCOUNTER, ENCOUNTER_LOCATION, APPOINTMENT_WITH,
    COMMUNITY_OF_SERVICE, PATIENT, GROUP_NAME, GROUP_TIME, _, ACTIVITY_TIME = WIRE_ADD.split("|", -1)
  RECORD_IEN = WIRE_EDIT.split("|", -1)[1]
  OTHER_PATIENT = "990037"
  OTHER_PROVIDER = "1"
  NOT_ON_FILE = "999999"
  DATE_BEFORE_DD_MIN = "1891231"
  DATE_AFTER_TODAY = "3991231"

  FULL_KWARGS = {
    provider: PROVIDER, program: PROGRAM, clinic: CLINIC, type_of_contact: TYPE_OF_CONTACT,
    encounter_date: ENCOUNTER, encounter_location: ENCOUNTER_LOCATION, community_of_service: COMMUNITY_OF_SERVICE,
    appointment_with: APPOINTMENT_WITH, patient: PATIENT, group_name: GROUP_NAME, group_time: GROUP_TIME,
    activity_time: ACTIVITY_TIME
  }.freeze
  REQUIRED_KWARGS = FULL_KWARGS.slice(:provider, :program, :clinic, :type_of_contact, :encounter_location,
                                      :community_of_service, :patient)
                               .merge(encounter_date: ENCOUNTER.split(".").first).freeze
  EDIT_KWARGS = FULL_KWARGS.merge(record_ien: RECORD_IEN).freeze
  NO_GROUP_KWARGS = EDIT_KWARGS.merge(group_name: "", group_time: nil, activity_time: nil).freeze
  EDIT_EXPLICIT_KEYS = %i[
    program clinic type_of_contact encounter_location community_of_service appointment_with group_name
  ].freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow = "add", **opts) = @client = AmhgReplay.flow(SLUG, flow, **opts)

  # A flow with one RPC's reply at index answered by another capture's reply.
  def replay_with(rpc, index, reply, flow: "add", **opts)
    script = CapturedReplies.flow_script(SLUG, flow)
    script[rpc][index] = reply
    @client = AmhgReplay.use(AmhgReplay::Client.new(script, **opts))
  end

  def flow_raw(flow, rpc, index) = CapturedReplies.flow_script(SLUG, flow).fetch(rpc).fetch(index)
  def sent = @client.calls.select { |c| c[:rpc].is_a?(String) }.map { |c| [ c[:rpc], c[:params] ] }
  def amhg_calls = @client.calls.select { |c| c[:rpc] == RPC }

  def after_save
    calls = @client.calls.select { |c| c[:rpc].is_a?(String) }
    calls.drop(calls.index { |c| c[:rpc] == RPC } + 1)
  end

  def assert_refused_before_amhg(pattern, flow, **kwargs)
    replay(flow)
    err = assert_raises(BH::SaveError) { BH.save_visit(**kwargs) }
    assert_match pattern, err.message
    assert_empty amhg_calls, "nothing may reach #{RPC}"
    assert_equal CapturedReplies.flow_calls(SLUG, flow), sent
    err
  end

  # Refused before any RPC but the server's today, which the date guard may
  # read first.
  def assert_input_validation_refusal(label = nil, **kwargs)
    @client = AmhgReplay.use(AmhgReplay::Client.new({ ORWU_DT => [ flow_raw("add", ORWU_DT, 0) ] }))
    assert_raises(BH::SaveError, label.to_s) { BH.save_visit(**kwargs) }
    assert_empty @client.rpcs_called - [ ORWU_DT ], "input validation must refuse before any other RPC (#{label})"
  end

  # The add flow sent another wire than the one recorded: the guards let it
  # through, and the read-back of the recorded save then does not confirm it.
  def assert_accepted_and_sent(wire, **kwargs)
    replay
    assert_raises(BH::SaveError) { BH.save_visit(**kwargs) }
    assert_equal [ [ wire ] ], amhg_calls.map { |c| c[:params] }
  end

  def assert_outcome_unknown(err, record_ien)
    assert_match(/may have been filed|outcome unknown/i, err.message)
    assert_includes err.message, record_ien
    [ PATIENT, GROUP_NAME, PROGRAM ].each { |v| refute_includes err.message, v }
  end

  def with_piece(wire, index, value)
    pieces = wire.split("|", -1)
    pieces[index] = value
    pieces.join("|")
  end

  # --- the captured saves -----------------------------------------------------

  def test_the_captured_add_returns_the_record_ien_the_build_filed
    replay

    assert_equal RECORD_IEN, BH.save_visit(**FULL_KWARGS)
  end

  # The server's today, a pointer read per filed pointer and the provider, the
  # patient, the sixteen-piece write, the visit read-back with the group
  # fields, and the primary provider list: each request is the one the build
  # answered.
  def test_each_add_request_is_the_one_the_build_answered
    replay
    BH.save_visit(**FULL_KWARGS)

    assert_equal CapturedReplies.flow_calls(SLUG, "add"), sent
    assert_equal 16, WIRE_ADD.split("|", -1).length
  end

  def test_an_add_of_the_required_fields_only_sends_blank_optional_pieces
    replay("add_required")

    refute_empty BH.save_visit(**REQUIRED_KWARGS, appointment_with: nil)
    assert_equal CapturedReplies.flow_calls(SLUG, "add_required"), sent
  end

  # An edit reads the visit (.08, 1112) and its primary provider before the
  # pointers, then reads both back after the write.
  def test_each_edit_request_is_the_one_the_build_answered
    replay("edit")

    assert_equal RECORD_IEN, BH.save_visit(**EDIT_KWARGS)
    assert_equal CapturedReplies.flow_calls(SLUG, "edit"), sent
  end

  # A blank group name on an edit means no group change: the group pieces are
  # sent blank and not read back.
  def test_an_edit_with_a_blank_group_name_sends_and_reads_back_no_group_fields
    replay("edit_no_group_change")

    assert_equal RECORD_IEN, BH.save_visit(**NO_GROUP_KWARGS)
    assert_equal CapturedReplies.flow_calls(SLUG, "edit_no_group_change"), sent
  end

  def test_the_write_runs_under_amhgrpc_and_the_reads_under_the_fileman_context
    replay
    BH.save_visit(**FULL_KWARGS)

    @client.calls.select { |c| c[:rpc].is_a?(String) && c[:rpc] != ORWU_DT }.each do |c|
      assert_equal(c[:rpc] == RPC ? "AMHGRPC" : AmhgReplay::FILEMAN_CONTEXT, c[:context], c[:rpc])
    end
    assert_equal [ "AMHGRPC", AmhgReplay::FILEMAN_CONTEXT ], @client.binds
  end

  def test_a_session_with_no_context_rebinds_the_fileman_context_for_the_read_backs
    %w[add edit].each do |flow|
      replay(flow, context: nil)
      capture_io { BH.save_visit(**(flow == "add" ? FULL_KWARGS : EDIT_KWARGS)) }

      assert_equal [ "AMHGRPC", AmhgReplay::FILEMAN_CONTEXT ], @client.binds, flow
      after_save.each { |c| assert_equal AmhgReplay::FILEMAN_CONTEXT, c[:context], "#{flow}: #{c[:rpc]}" }
    end
  end

  # DDR GETS of the visit file is read as call_rpc lines, never as a GLOBAL
  # ARRAY, whatever the client offers.
  def test_visit_reads_never_use_the_global_array_read
    replay
    @client.define_singleton_method(:call_rpc_global_array) do |rpc_name, *params|
      raise "#{rpc_name} read as a GLOBAL ARRAY" unless rpc_name == RPC

      super(rpc_name, *params)
    end

    assert_equal RECORD_IEN, BH.save_visit(**FULL_KWARGS)
  end

  # --- refusals the build's replies lead to -----------------------------------

  def test_a_clinic_not_on_file_is_refused
    assert_refused_before_amhg(/clinic/i, "add_clinic_not_on_file", **FULL_KWARGS, clinic: NOT_ON_FILE)
  end

  def test_an_add_for_a_patient_not_on_file_is_refused
    assert_refused_before_amhg(/patient/i, "add_patient_not_on_file", **FULL_KWARGS, patient: NOT_ON_FILE)
  end

  def test_an_edit_naming_another_patient_is_refused_after_the_pre_read
    assert_refused_before_amhg(/patient/i, "edit_other_patient", **EDIT_KWARGS, patient: OTHER_PATIENT)
  end

  # The visit's primary is the signed-on provider; the refusal comes from the provider
  # list, before any read names the provider, so any other DUZ is refused alike.
  def test_an_edit_by_a_provider_who_is_not_the_primary_is_refused
    assert_refused_before_amhg(/primary/i, "edit_not_primary", **EDIT_KWARGS, provider: OTHER_PROVIDER)
  end

  def test_an_edit_of_a_record_not_on_file_is_refused
    assert_refused_before_amhg(/could not be read|not on file/i, "edit_record_not_on_file",
                               **FULL_KWARGS, record_ien: NOT_ON_FILE)
  end

  # A refused pointer read is reported as unreadable, not as missing.
  def test_a_pointer_read_the_session_is_refused_is_unreadable_not_missing
    replay.fail_on(GETS, RpmsRpc::Client::RpcRefusedError.new("synthetic"))

    err = assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }
    assert_match(/clinic could not be read/, err.message)
    refute_match(/not on file/, err.message)
    assert_empty amhg_calls
  end

  # The build echoed 999999 for an edit of a record no visit has: a reply
  # naming another record than the one edited is not a confirmation.
  def test_an_edit_reply_naming_another_record_is_outcome_unknown
    replay_with(RPC, 0, CapturedReplies.raw(SLUG, "save_record_not_on_file"), flow: "edit")

    err = assert_raises(BH::SaveError) { BH.save_visit(**EDIT_KWARGS) }
    refute_empty amhg_calls
    assert_outcome_unknown(err, RECORD_IEN)
  end

  # --- read-backs that do not match what was sent -----------------------------

  def test_values_the_read_back_does_not_hold_are_not_confirmed
    [
      { encounter_date: ENCOUNTER.split(".").first }, { appointment_with: "WALK-IN" },
      { group_name: "SYNTH GROUP BETA" }, { group_time: "46" }, { activity_time: "31" }
    ].each do |change|
      replay
      err = assert_raises(BH::SaveError, change.inspect) { BH.save_visit(**FULL_KWARGS, **change) }
      assert_outcome_unknown(err, RECORD_IEN)
    end
  end

  # The add read back with the required-only add's visit (another record, no
  # group fields) or its provider list is not confirmed.
  def test_a_read_back_of_another_visit_is_not_confirmed
    [ [ GETS, 6 ], [ LISTER, 0 ] ].each do |rpc, index|
      replay_with(rpc, index, flow_raw("add_required", rpc, index))
      err = assert_raises(BH::SaveError, rpc) { BH.save_visit(**FULL_KWARGS) }
      assert_outcome_unknown(err, RECORD_IEN)
    end
  end

  def test_a_read_back_the_build_answers_with_an_error_is_not_confirmed
    replay_with(GETS, 6, flow_raw("edit_record_not_on_file", GETS, 0))

    assert_outcome_unknown(assert_raises(BH::SaveError) { BH.save_visit(**FULL_KWARGS) }, RECORD_IEN)
  end

  # --- a wire lost or never sent ----------------------------------------------

  def test_a_wire_lost_during_the_write_is_outcome_unknown_and_keeps_the_cause
    [ RpmsRpc::Client::ConnectionError, RpmsRpc::Client::RpcTimeoutError, RpmsRpc::Client::RpcMError,
      RpmsRpc::Client::RpcError ].each do |klass|
      replay("edit").fail_on(RPC, klass.new("SYNTH_VISIT_TRAP"))
      err = assert_raises(BH::SaveError, klass.name) { BH.save_visit(**EDIT_KWARGS) }
      assert_outcome_unknown(err, RECORD_IEN)
      assert_kind_of klass, err.cause
      refute_includes err.message, "SYNTH_VISIT_TRAP"
    end
  end

  def test_with_no_context_a_lost_wire_still_rebinds_the_fileman_context
    replay(context: nil).fail_on(RPC, RpmsRpc::Client::RpcTimeoutError.new("synthetic"))

    err = assert_raises(BH::SaveError) { capture_io { BH.save_visit(**FULL_KWARGS) } }
    assert_kind_of RpmsRpc::Client::RpcTimeoutError, err.cause
    assert_equal [ "AMHGRPC", AmhgReplay::FILEMAN_CONTEXT ], @client.binds
  end

  # The write landed but the FileMan context cannot be re-bound for the
  # read-back: outcome unknown, naming the record from the reply (add) or the
  # one edited.
  def test_a_refused_rebind_after_the_write_names_the_record
    [ [ "add", FULL_KWARGS ], [ "edit", EDIT_KWARGS ] ].each do |flow, kwargs|
      replay(flow, context: nil).refuse_bind(AmhgReplay::FILEMAN_CONTEXT)
      err = assert_raises(BH::SaveError, flow) { capture_io { BH.save_visit(**kwargs) } }
      assert_match(/AMHG SAVE VISIT outcome unknown/, err.message)
      assert_match(/record #{RECORD_IEN} may have been filed/, err.message)
    end
  end

  def test_a_refused_rebind_inside_a_host_rescue_keeps_the_lost_wire
    replay(context: nil).fail_on(RPC, RpmsRpc::Client::RpcTimeoutError.new("synthetic"))
    @client.refuse_bind(AmhgReplay::FILEMAN_CONTEXT)

    err = begin
      raise "host"
    rescue StandardError
      assert_raises(BH::SaveError) { capture_io { BH.save_visit(**FULL_KWARGS) } }
    end
    assert_kind_of RpmsRpc::Client::RpcTimeoutError, err.cause
    assert_nil @client.current_context
  end

  def test_a_frame_too_long_to_send_is_nothing_sent_not_outcome_unknown
    replay(context: nil).fail_on(RPC, RpmsRpc::Client::FrameTooLongError.new("synthetic"), sent: false)

    err = assert_raises(BH::SaveError) { capture_io { BH.save_visit(**FULL_KWARGS) } }
    refute_match(/outcome unknown/i, err.message)
    assert_match(/nothing was sent/i, err.message)
    assert_kind_of RpmsRpc::Client::FrameTooLongError, err.cause
    assert_equal AmhgReplay::FILEMAN_CONTEXT, @client.current_context
  end

  def test_an_rpc_the_session_may_not_run_is_not_wrapped
    [ RpmsRpc::Client::RpcNotAvailableError, RpmsRpc::Client::RpcRefusedError ].each do |klass|
      replay.fail_on(RPC, klass.new("synthetic"), sent: false)
      assert_raises(klass) { BH.save_visit(**FULL_KWARGS) }
      assert_empty amhg_calls
    end
  end

  # --- argument guards --------------------------------------------------------

  def test_save_error_is_a_subclass_of_rpms_rpc_error
    assert_operator BH::SaveError, :<, RpmsRpc::Error
  end

  def test_unknown_keywords_are_argument_errors
    { esign: true, arrival_time: "09:30" }.each do |key, value|
      @client = AmhgReplay.silent
      assert_raises(ArgumentError, key.to_s) { BH.save_visit(**FULL_KWARGS, key => value) }
      assert_empty @client.calls
    end
  end

  def test_a_missing_provider_encounter_date_or_patient_is_refused
    %i[provider encounter_date patient].each do |key|
      [ nil, "", "   " ].each do |blank|
        assert_input_validation_refusal("#{key} #{blank.inspect}", **FULL_KWARGS, key => blank)
      end
    end
  end

  def test_a_missing_dd_required_field_is_refused_on_add_and_edit
    %i[program clinic type_of_contact encounter_location community_of_service].each do |key|
      assert_input_validation_refusal("add #{key} nil", **REQUIRED_KWARGS, key => nil)
      assert_input_validation_refusal("add #{key} blank", **REQUIRED_KWARGS, key => "")
      assert_input_validation_refusal("edit #{key} nil", **EDIT_KWARGS, key => nil)
      assert_input_validation_refusal("edit #{key} blank", **NO_GROUP_KWARGS, key => "")
    end
    EDIT_EXPLICIT_KEYS.each { |key| assert_input_validation_refusal("edit #{key} omitted", **EDIT_KWARGS, key => nil) }
  end

  def test_iens_and_pointers_that_are_not_positive_integers_are_refused
    %w[0 -1 abc].each do |bad|
      %i[patient provider clinic type_of_contact encounter_location community_of_service].each do |key|
        assert_input_validation_refusal("#{key} #{bad}", **FULL_KWARGS, key => bad)
      end
      assert_input_validation_refusal("record_ien #{bad}", **FULL_KWARGS, record_ien: bad)
    end
    [ "", "   " ].each { |blank| assert_input_validation_refusal("record_ien blank", **FULL_KWARGS, record_ien: blank) }
  end

  def test_an_encounter_date_that_is_malformed_too_early_or_after_the_servers_today_is_refused
    [ "yesterday", "2026-10-31", "326101", "12345678", "0251031", DATE_BEFORE_DD_MIN, DATE_AFTER_TODAY ].each do |bad|
      assert_input_validation_refusal("encounter_date #{bad}", **FULL_KWARGS, encounter_date: bad)
    end
  end

  def test_program_or_appointment_with_outside_the_filed_sets_is_refused
    assert_input_validation_refusal("program", **FULL_KWARGS, program: "ADULT OUTPATIENT")
    assert_input_validation_refusal("appointment", **FULL_KWARGS, appointment_with: "SCHEDULED")
    assert_input_validation_refusal("program @", **FULL_KWARGS, program: "@")
  end

  def test_group_fields_out_of_bounds_are_refused
    [ "X" * 31, "#{'a' * 29}é", "@", " @ " ].each do |bad|
      assert_input_validation_refusal("group_name #{bad}", **FULL_KWARGS, group_name: bad)
    end
    assert_input_validation_refusal("edit group_name @", **EDIT_KWARGS, group_name: "@")
    assert_input_validation_refusal("edit nil group_name", **NO_GROUP_KWARGS, group_name: nil)
    assert_input_validation_refusal("edit nil group_time", **EDIT_KWARGS, group_time: nil)
    assert_input_validation_refusal("edit nil activity_time", **EDIT_KWARGS, activity_time: nil)
    assert_input_validation_refusal("time without group", **FULL_KWARGS, group_name: "", group_time: GROUP_TIME)
    assert_input_validation_refusal("time without group", **FULL_KWARGS, group_name: "   ", activity_time: ACTIVITY_TIME)
    assert_input_validation_refusal("time without group", **FULL_KWARGS, group_name: nil, group_time: "10")
    %w[-1 10000 abc 12.5 9999.1].each do |bad|
      assert_input_validation_refusal("group_time #{bad}", **FULL_KWARGS, group_time: bad)
      assert_input_validation_refusal("activity_time #{bad}", **FULL_KWARGS, activity_time: bad)
    end
    assert_input_validation_refusal("activity_time 0", **FULL_KWARGS, activity_time: "0")
  end

  def test_group_fields_at_their_bounds_are_sent
    assert_accepted_and_sent(with_piece(WIRE_ADD, 12, "€" * 10), **FULL_KWARGS, group_name: "€" * 10)
    assert_accepted_and_sent(with_piece(WIRE_ADD, 12, "Group @ clinic"), **FULL_KWARGS, group_name: "Group @ clinic")
    assert_accepted_and_sent(with_piece(with_piece(WIRE_ADD, 13, "0"), 15, "1"),
                             **FULL_KWARGS, group_time: "0", activity_time: "1")
    assert_accepted_and_sent(with_piece(WIRE_ADD, 15, "9999"), **FULL_KWARGS, activity_time: "9999")
  end

  # A blank appointment/walk-in on an edit clears .11.
  def test_an_edit_may_send_a_blank_appointment_with
    replay("edit_no_group_change")
    assert_raises(BH::SaveError) { BH.save_visit(**NO_GROUP_KWARGS, appointment_with: "") }

    assert_equal [ [ with_piece(WIRE_EDIT_NO_GROUP, 9, "") ] ], amhg_calls.map { |c| c[:params] }
  end

  def test_separators_control_characters_and_foreign_encodings_are_refused
    FULL_KWARGS.each_key do |key|
      assert_input_validation_refusal("pipe #{key}", **FULL_KWARGS, key => "a|b")
      assert_input_validation_refusal("caret #{key}", **FULL_KWARGS, key => "bad^value")
      %w[UTF-16LE UTF-16BE UTF-32LE UTF-32BE].each do |encoding|
        assert_input_validation_refusal("#{key} #{encoding}", **FULL_KWARGS, key => "SYNTH".encode(encoding))
      end
      [ "SYNTH caf\xE9".dup.force_encoding(Encoding::ISO_8859_1),
        "it\xE2\x80\x99s".b.force_encoding(Encoding::WINDOWS_1252) ].each do |bad|
        assert_input_validation_refusal("#{key} #{bad.encoding}", **FULL_KWARGS, key => bad)
      end
    end
    [ "\x1e", "\x1f", "\x01", "\x7f", "ok\nbad", "SYN\u0085TH" ].each do |bad|
      assert_input_validation_refusal("group_name #{bad.inspect}", **FULL_KWARGS, group_name: bad)
    end
    assert_input_validation_refusal("invalid bytes", **FULL_KWARGS, group_name: String.new("\xC0\x80", encoding: Encoding::ASCII_8BIT))
    bad = Object.new
    bad.define_singleton_method(:to_s) { "\xFF".b }
    assert_input_validation_refusal("invalid to_s", **FULL_KWARGS, group_name: bad)
  end

  # --- registry ---------------------------------------------------------------

  def test_retry_safety_classifies_save_visit_as_non_idempotent_write
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(BH, :save_visit)
  end

  def test_required_rpcs_lists_amhg_save_visit_under_behavioral_health
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    assert_includes doc.fetch("modules").fetch("RpmsRpc::BehavioralHealth"), RPC
  end
end
