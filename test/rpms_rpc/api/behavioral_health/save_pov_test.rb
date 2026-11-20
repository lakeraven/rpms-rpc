# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require "rpms_rpc/mappings"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/retry_safety"
require_relative "amhg_replay"

# AMHG SAVE POV: POV^AMHGSVF (AMHGSVF.m:47-75), AXIS2/3/4/5, CLNPOV^AMHGEVF.
#
# The guard and refusal cases, read from the conversations the pinned build
# had with BehavioralHealth.save_pov (test/fixtures/captured_replies/amhg-save-pov.yml):
# a full save and a replace-all save on one BH visit for synthetic patient
# DFN 990035, and the refusals the build's replies lead to (the visit names
# another patient, a problem or Axis IV pointer not on file). The round trip
# itself is proven by test/live/behavioral_health_save_pov_live_test.rb
# (rpms-rpc#622, option b).
#
# The build answers AMHG SAVE POV with the record IEN it was sent, even for a
# problem pointer or a record no entry has (captures save_problem_not_on_file
# and save_record_not_on_file). The reply alone proves nothing was filed; the
# pre-reads and the read-back are what this file guards.
class BehavioralHealthSavePovTest < Minitest::Test
  BH = RpmsRpc::BehavioralHealth
  SLUG = "amhg-save-pov"
  RPC = "AMHG SAVE POV"
  GETS = "DDR GETS ENTRY DATA"
  LISTER = "DDR LISTER"
  MHSS_PROBLEM_FILE = "9002012.2"
  PSYCHOSOCIAL_FILE = "9002012.9"
  AXIS_III_FIELD = "5301"

  ROOT = File.expand_path("../../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  def self.sent_wire(flow) = CapturedReplies.flow(SLUG, flow).find { |c| c["rpc"] == RPC }.fetch("inputs").first

  WIRE_FULL = sent_wire("save")
  WIRE_REPLACE = sent_wire("replace")
  _, RECORD_IEN, DIAGNOSES, AXIS_III, AXIS_IV, AXIS_V, PATIENT, GAF = WIRE_FULL.split("|", -1)
  PROB_ONE, NARR_ONE, PROB_TWO, NARR_TWO = DIAGNOSES.split("*").flat_map { |d| d.split("~~") }
  AX4_ONE, AX4_TWO = AXIS_IV.split("*").map { |s| s.delete_suffix("~~") }
  _, _, REPLACE_DIAGNOSIS, _, REPLACE_AXIS_IV, REPLACE_AXIS_V = WIRE_REPLACE.split("|", -1)
  PROB_REPLACE, NARR_REPLACE = REPLACE_DIAGNOSIS.split("~~")
  AX4_REPLACE = REPLACE_AXIS_IV.delete_suffix("~~")
  OTHER_PATIENT = "990036"
  NOT_ON_FILE = "999999"

  FULL_KWARGS = {
    record_ien: RECORD_IEN, patient: PATIENT,
    diagnoses: [ { problem: PROB_ONE, narrative: NARR_ONE }, { problem: PROB_TWO, narrative: NARR_TWO } ],
    axis_iii: AXIS_III, axis_iv: [ AX4_ONE, AX4_TWO ], axis_v: AXIS_V, gaf: GAF
  }.freeze

  REPLACE_KWARGS = {
    record_ien: RECORD_IEN, patient: PATIENT, diagnoses: [ { problem: PROB_REPLACE, narrative: NARR_REPLACE } ],
    axis_iv: [ AX4_REPLACE ], axis_v: REPLACE_AXIS_V, gaf: "", axis_iii: ""
  }.freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow = "save", **opts) = @client = AmhgReplay.flow(SLUG, flow, **opts)

  # The save flow with one step answered by another capture's reply.
  def replay_with(rpc, index, reply, flow: "save", **opts)
    script = CapturedReplies.flow_script(SLUG, flow)
    script[rpc][index] = reply
    @client = AmhgReplay.use(AmhgReplay::Client.new(script, **opts))
  end

  def raw(name) = CapturedReplies.raw(SLUG, name)
  def flow_raw(flow, rpc, index) = CapturedReplies.flow_script(SLUG, flow).fetch(rpc).fetch(index)
  def sent = @client.calls.select { |c| c[:rpc].is_a?(String) }.map { |c| [ c[:rpc], c[:params] ] }
  def amhg_calls = @client.calls.select { |c| c[:rpc] == RPC }

  def after_amhg
    calls = @client.calls.select { |c| c[:rpc].is_a?(String) }
    calls.drop(calls.index { |c| c[:rpc] == RPC } + 1)
  end

  def assert_refused_before_amhg(pattern = nil, **kwargs)
    err = assert_raises(BH::SaveError) { BH.save_pov(**kwargs) }
    assert_match pattern, err.message if pattern
    assert_empty amhg_calls, "nothing may reach #{RPC}"
    err
  end

  def assert_input_validation_refusal(pattern = nil, **kwargs)
    @client = AmhgReplay.silent
    err = assert_raises(BH::SaveError) { BH.save_pov(**kwargs) }
    assert_empty @client.calls, "input validation must refuse before any RPC"
    assert_match pattern, err.message if pattern
    err
  end

  def assert_outcome_unknown(err)
    assert_match(/may have been changed|outcome unknown/i, err.message)
    assert_includes err.message, RECORD_IEN
    refute_includes err.message, PATIENT
    refute_includes err.message, NARR_ONE
  end

  # --- the captured saves -----------------------------------------------------

  def test_the_captured_save_returns_the_record_ien
    replay

    assert_equal RECORD_IEN, BH.save_pov(**FULL_KWARGS)
  end

  # The visit pre-read, a pointer read per problem and stressor, the eight-piece
  # write, and the POV, Axis IV, Axis V and Axis III read-backs: each request is
  # the one the build answered.
  def test_each_request_is_the_one_the_build_answered
    replay
    BH.save_pov(**FULL_KWARGS)

    assert_equal CapturedReplies.flow_calls(SLUG, "save"), sent
    assert_equal 8, amhg_calls.first[:params].first.split("|", -1).length
  end

  def test_a_second_save_sends_only_the_new_wire_and_the_build_replaced_every_row
    replay("replace")

    assert_equal RECORD_IEN, BH.save_pov(**REPLACE_KWARGS)
    assert_equal CapturedReplies.flow_calls(SLUG, "replace"), sent
  end

  # A blank Axis III is not read back (5301).
  def test_a_blank_axis_iii_is_not_read_back
    replay("replace")
    BH.save_pov(**REPLACE_KWARGS)

    refute(after_amhg.any? { |c| c[:rpc] == GETS && c[:params].first["FIELDS"].include?(AXIS_III_FIELD) })
  end

  def test_the_pointer_reads_run_before_the_write
    replay
    BH.save_pov(**FULL_KWARGS)

    calls = @client.calls.select { |c| c[:rpc].is_a?(String) }
    write = calls.index { |c| c[:rpc] == RPC }
    { MHSS_PROBLEM_FILE => [ PROB_ONE, PROB_TWO ], PSYCHOSOCIAL_FILE => [ AX4_ONE, AX4_TWO ] }.each do |file, iens|
      iens.each do |ien|
        at = calls.index { |c| c[:rpc] == GETS && c[:params].first.values_at("FILE", "IENS") == [ file, "#{ien}," ] }
        refute_nil at, "no pointer read of #{file} #{ien}"
        assert_operator at, :<, write
      end
    end
  end

  def test_the_write_runs_under_amhgrpc_and_restores_the_callers_context
    replay
    BH.save_pov(**FULL_KWARGS)

    assert_equal "AMHGRPC", amhg_calls.first[:context]
    after_amhg.each { |c| assert_equal AmhgReplay::FILEMAN_CONTEXT, c[:context], "#{c[:rpc]} after the write" }
    assert_equal [ "AMHGRPC", AmhgReplay::FILEMAN_CONTEXT ], @client.binds
  end

  # A session that declared no context cannot be restored by the scope; the
  # read-backs re-bind the FileMan context rather than run under AMHGRPC.
  def test_a_session_with_no_context_rebinds_the_fileman_context_for_the_read_backs
    replay(context: nil)
    capture_io { BH.save_pov(**FULL_KWARGS) }

    assert_equal [ "AMHGRPC", AmhgReplay::FILEMAN_CONTEXT ], @client.binds
    after_amhg.each { |c| assert_equal AmhgReplay::FILEMAN_CONTEXT, c[:context], "#{c[:rpc]} after the write" }
  end

  # --- refusals the build's replies lead to -----------------------------------

  def test_a_visit_of_another_patient_is_refused_after_the_pre_read
    replay("other_patient")

    assert_refused_before_amhg(**FULL_KWARGS, patient: OTHER_PATIENT)
    assert_equal CapturedReplies.flow_calls(SLUG, "other_patient"), sent
  end

  def test_a_problem_pointer_not_on_file_is_refused
    replay("problem_not_on_file")

    err = assert_refused_before_amhg(**FULL_KWARGS, diagnoses: [ { problem: NOT_ON_FILE, narrative: NARR_ONE } ])
    assert_match(/problem/i, err.message)
    assert_equal CapturedReplies.flow_calls(SLUG, "problem_not_on_file"), sent
  end

  def test_an_axis_iv_pointer_not_on_file_is_refused
    replay("axis_iv_not_on_file")

    err = assert_refused_before_amhg(**FULL_KWARGS, axis_iv: [ NOT_ON_FILE ])
    assert_match(/axis iv/i, err.message)
    assert_equal CapturedReplies.flow_calls(SLUG, "axis_iv_not_on_file"), sent
  end

  # The build echoed 999999 for a record no visit has: a reply naming another
  # record than the one sent is not a confirmation.
  def test_a_reply_naming_another_record_is_outcome_unknown
    replay_with(RPC, 0, raw("save_record_not_on_file"))

    err = assert_raises(BH::SaveError) { BH.save_pov(**FULL_KWARGS) }
    refute_empty amhg_calls
    assert_outcome_unknown(err)
  end

  # --- read-backs that do not match what was sent -----------------------------

  def test_values_the_read_back_does_not_hold_are_not_confirmed
    [
      { diagnoses: [ { problem: PROB_ONE, narrative: "SYNTH OTHER NARR" }, FULL_KWARGS[:diagnoses][1] ] },
      { axis_v: "60" },
      { gaf: "13" },
      { axis_iii: "SYNTH OTHER AXIS III" }
    ].each do |change|
      replay
      err = assert_raises(BH::SaveError, change.inspect) { BH.save_pov(**FULL_KWARGS, **change) }
      assert_outcome_unknown(err)
    end
  end

  # The replace-all save read back with the first save's rows (two POV rows,
  # stressors 1 and 2): stale rows and a missing stressor are not confirmed.
  def test_a_read_back_with_stale_rows_is_not_confirmed
    [ [ 0, "the first save's POV rows" ], [ 1, "the first save's Axis IV rows" ] ].each do |index, label|
      replay_with(LISTER, index, flow_raw("save", LISTER, index), flow: "replace")
      err = assert_raises(BH::SaveError, label) { BH.save_pov(**REPLACE_KWARGS) }
      assert_outcome_unknown(err)
    end
  end

  def test_a_read_back_the_build_answers_with_an_error_is_not_confirmed
    replay_with(LISTER, 0, flow_raw("problem_not_on_file", GETS, 1))

    assert_outcome_unknown(assert_raises(BH::SaveError) { BH.save_pov(**FULL_KWARGS) })
  end

  # --- a wire lost or never sent ----------------------------------------------

  def test_a_wire_lost_during_the_write_is_outcome_unknown_and_keeps_the_cause
    [ RpmsRpc::Client::ConnectionError, RpmsRpc::Client::RpcTimeoutError, RpmsRpc::Client::RpcMError ].each do |klass|
      replay.fail_on(RPC, klass.new("synthetic"))
      err = assert_raises(BH::SaveError, klass.name) { BH.save_pov(**FULL_KWARGS) }
      assert_outcome_unknown(err)
      assert_kind_of klass, err.cause
    end
  end

  def test_with_no_context_a_lost_wire_still_rebinds_the_fileman_context
    replay(context: nil).fail_on(RPC, RpmsRpc::Client::RpcTimeoutError.new("synthetic"))

    err = assert_raises(BH::SaveError) { capture_io { BH.save_pov(**FULL_KWARGS) } }
    assert_kind_of RpmsRpc::Client::RpcTimeoutError, err.cause
    assert_equal [ "AMHGRPC", AmhgReplay::FILEMAN_CONTEXT ], @client.binds
    assert_equal AmhgReplay::FILEMAN_CONTEXT, @client.current_context
  end

  def test_a_refused_rebind_does_not_replace_the_lost_wire
    replay(context: nil).fail_on(RPC, RpmsRpc::Client::RpcTimeoutError.new("synthetic"))
    @client.refuse_bind(AmhgReplay::FILEMAN_CONTEXT)

    err = assert_raises(BH::SaveError) { capture_io { BH.save_pov(**FULL_KWARGS) } }
    assert_kind_of RpmsRpc::Client::RpcTimeoutError, err.cause
    assert_nil @client.current_context
  end

  def test_a_frame_too_long_to_send_is_nothing_sent_not_outcome_unknown
    replay(context: nil).fail_on(RPC, RpmsRpc::Client::FrameTooLongError.new("synthetic"), sent: false)

    err = assert_raises(BH::SaveError) { capture_io { BH.save_pov(**FULL_KWARGS) } }
    refute_match(/outcome unknown/i, err.message)
    assert_match(/nothing was sent/i, err.message)
    assert_kind_of RpmsRpc::Client::FrameTooLongError, err.cause
    assert_equal AmhgReplay::FILEMAN_CONTEXT, @client.current_context
  end

  def test_an_rpc_the_session_may_not_run_is_not_wrapped
    [ RpmsRpc::Client::RpcNotAvailableError, RpmsRpc::Client::RpcRefusedError ].each do |klass|
      replay.fail_on(RPC, klass.new("synthetic"), sent: false)
      assert_raises(klass) { BH.save_pov(**FULL_KWARGS) }
      assert_empty amhg_calls
    end
  end

  # --- argument guards: refused before any RPC --------------------------------

  def test_save_error_is_a_subclass_of_rpms_rpc_error
    assert_operator BH::SaveError, :<, RpmsRpc::Error
  end

  def test_diagnoses_must_be_present_valid_and_distinct
    assert_input_validation_refusal(/diagnos/i, **FULL_KWARGS, diagnoses: [])
    assert_input_validation_refusal(/diagnos/i, **FULL_KWARGS, diagnoses: nil)
    assert_input_validation_refusal(/narrative/i, **FULL_KWARGS, diagnoses: [ { problem: PROB_ONE, narrative: "" } ])
    assert_input_validation_refusal(/problem/i, **FULL_KWARGS, diagnoses: [ { problem: "0", narrative: NARR_ONE } ])
    assert_input_validation_refusal(/problem/i, **FULL_KWARGS, diagnoses: [ { problem: "abc", narrative: NARR_ONE } ])
    dup = [ { problem: PROB_ONE, narrative: NARR_ONE }, { problem: PROB_ONE, narrative: NARR_TWO } ]
    assert_input_validation_refusal(/problem|diagnos/i, **FULL_KWARGS, diagnoses: dup)
    assert_input_validation_refusal(/axis iv/i, **FULL_KWARGS, axis_iv: [ AX4_ONE, AX4_ONE ])
  end

  def test_more_than_twenty_five_diagnoses_or_stressors_are_refused
    problems = (501..526).map { |n| { problem: n.to_s, narrative: "SYNTH NARR #{n}" } }
    assert_input_validation_refusal(/diagnos|25/i, **FULL_KWARGS, diagnoses: problems)
    assert_input_validation_refusal(/axis iv|25/i, **FULL_KWARGS, axis_iv: (601..626).map(&:to_s))
  end

  def test_each_omitted_required_keyword_is_an_argument_error
    %i[record_ien patient diagnoses axis_iv axis_v gaf].each do |key|
      @client = AmhgReplay.silent
      assert_raises(ArgumentError, key.to_s) { BH.save_pov(**FULL_KWARGS.except(key)) }
      assert_empty @client.calls
    end
  end

  def test_nil_axis_v_or_gaf_is_refused
    assert_input_validation_refusal(/axis v is required/i, **FULL_KWARGS, axis_v: nil)
    assert_input_validation_refusal(/gaf is required/i, **FULL_KWARGS, gaf: nil)
  end

  def test_bad_integer_tokens_are_refused
    %w[0 -1 01 1.5 abc].each do |bad|
      assert_input_validation_refusal(/record ien must be a positive integer/i, **FULL_KWARGS, record_ien: bad)
      assert_input_validation_refusal(/patient must be a positive integer/i, **FULL_KWARGS, patient: bad) unless bad == "abc"
      assert_input_validation_refusal(/axis iv must be a positive integer/i, **FULL_KWARGS, axis_iv: [ bad ]) unless bad == "abc"
    end
    %w[-1 01 1.5].each do |bad|
      assert_input_validation_refusal(/problem must be a positive integer/i,
                                      **FULL_KWARGS, diagnoses: [ { problem: bad, narrative: NARR_ONE } ])
    end
    assert_input_validation_refusal(/record ien is required/i, **FULL_KWARGS, record_ien: "")
    assert_input_validation_refusal(/patient is required/i, **FULL_KWARGS, patient: "")
    assert_input_validation_refusal(/patient is required/i, **FULL_KWARGS, patient: nil)
  end

  def test_separators_and_control_characters_are_refused
    [ "|", "~", "*", "^", "\x1e", "\x1f", "\x01", "ok\nbad" ].each do |bad|
      assert_input_validation_refusal(/separator|control/i,
                                      **FULL_KWARGS, diagnoses: [ { problem: PROB_ONE, narrative: bad } ])
    end
    c1 = "\u0085"
    assert_input_validation_refusal(/gaf|control|separator/i, **FULL_KWARGS, gaf: "12#{c1}")
    assert_input_validation_refusal(/axis iii|control|separator/i, **FULL_KWARGS, axis_iii: "SYN#{c1}TH")
    assert_input_validation_refusal(/axis iii|control|separator/i, **FULL_KWARGS, axis_iii: "line one\nline two")
  end

  def test_whitespace_only_and_delete_marker_values_are_refused
    assert_input_validation_refusal(/axis v/i, **FULL_KWARGS, axis_v: "   ")
    assert_input_validation_refusal(/gaf/i, **FULL_KWARGS, gaf: "   ")
    assert_input_validation_refusal(/axis iii/i, **FULL_KWARGS, axis_iii: "   ")
    assert_input_validation_refusal(/narrative/i, **FULL_KWARGS, diagnoses: [ { problem: PROB_ONE, narrative: "  " } ])
    assert_input_validation_refusal(/delete marker/i, **FULL_KWARGS, diagnoses: [ { problem: PROB_ONE, narrative: "@" } ])
    assert_input_validation_refusal(/delete marker/i, **FULL_KWARGS, gaf: "@")
    assert_input_validation_refusal(/delete marker/i, **FULL_KWARGS, axis_iii: " @ ")
  end

  # FNDNARR's input transform: 2-160 characters, not starting with - or .
  def test_a_narrative_outside_the_input_transform_is_refused
    [ "X", "N" * 161, "-SYNTH", ".SYNTH", "SYN\u0085TH", "AB".dup + "caf\xE9".b ].each do |bad|
      assert_input_validation_refusal(/narrative|utf-8|ascii/i,
                                      **FULL_KWARGS, diagnoses: [ { problem: PROB_ONE, narrative: bad } ])
    end
  end

  def test_axis_v_gaf_and_axis_iii_outside_their_ranges_are_refused
    [ 101, -1, "5.5", "abc" ].each { |bad| assert_input_validation_refusal(/axis v/i, **FULL_KWARGS, axis_v: bad) }
    assert_input_validation_refusal(/gaf/i, **FULL_KWARGS, gaf: "x" * 21)
    assert_input_validation_refusal(/axis iii/i, **FULL_KWARGS, axis_iii: "x" * 246)
  end

  def test_text_that_is_not_valid_utf8_is_refused
    assert_input_validation_refusal(**FULL_KWARGS, gaf: String.new("\xC0\x80", encoding: Encoding::ASCII_8BIT))
    latin1 = "SYNTH caf\xE9".dup.force_encoding(Encoding::ISO_8859_1)
    assert_input_validation_refusal(/not valid UTF-8/i, **FULL_KWARGS, axis_iii: latin1)
    bad = Object.new
    bad.define_singleton_method(:to_s) { "\xFF".b }
    assert_input_validation_refusal(**FULL_KWARGS, axis_v: bad)
  end

  # --- registry ---------------------------------------------------------------

  def test_retry_safety_classifies_save_pov_as_non_idempotent_write
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(BH, :save_pov)
  end

  def test_required_rpcs_lists_amhg_save_pov_under_behavioral_health
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    assert_includes doc.fetch("modules").fetch("RpmsRpc::BehavioralHealth"), RPC
  end
end
