# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/allergy"
require "rpms_rpc/retry_safety"

# ORWDAL32 SAVE ALLERGY — EDITSAVE^ORWDAL32 (ORWDAL32.m:119-128) ->
# UPDATE^GMRAGUI1 / NKA^GMRAGUI1 (GMRAGUI1.m:68-84, :86-148).
class AllergySaveTest < Minitest::Test
  DFN = "8791"
  RPC = "ORWDAL32 SAVE ALLERGY"

  # MESS^GMRAGUI1 (GMRAGUI1.m:151-157)
  LOCK_REPLY = "-1^Another user is editing this patient's allergy information.  " \
               "Please refresh/review the patient's information before proceeding."

  SYNTH_ALLERGY = {
    agent: "PENICILLIN",
    agent_pointer: "125;PSNDF(50.6,",
    type: "D",
    nature: "A",
    originator: "42",
    originated_at: "3261015.1045",
    observed_or_historical: "o",
    symptoms: [ { ien: "10", text: "RASH", date: "3261015" } ],
    comments: [ "synthetic comment" ],
    reaction_date: "3261015",
    severity: "2"
  }.freeze

  VALID_AGENT_POINTERS = [
    "125;PSNDF(50.6,",
    "125;GMRD(120.82,",
    "5;PS(50.416,",
    "7;PS(50.605,",
    "45;PSDRUG("
  ].freeze

  REQUIRED_RPCS_PATH = File.expand_path("../../../lib/rpms_rpc/required_rpcs.json", __dir__)

  def teardown
    RpmsRpc.reset!
  end

  # --- wiring (EDITSAVE^ORWDAL32: ORALIEN, ORDFN, OREDITED list) ------------

  def test_save_dispatches_orwdal32_save_allergy_with_formal_order_and_list_shape
    seed_save_reply("0")
    RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)

    call = save_call
    refute_nil call, "expected #{RPC}"
    # ORY is broker return; client params are ORALIEN, ORDFN, OREDITED (ORWDAL32.m:119).
    assert_equal [ "", DFN, expected_edited(SYNTH_ALLERGY) ], call[:params]
  end

  def test_save_success_without_progress_note
    seed_save_reply("0")
    result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
    assert result[:success]
    assert_nil result[:note_ien]
  end

  def test_save_success_with_progress_note_ien
    seed_save_reply("0^4242")
    result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
    assert result[:success]
    assert_equal 4242, result[:note_ien]
  end

  def test_save_maps_duplicate_failure
    agent = SYNTH_ALLERGY[:agent]
    seed_save_reply("-1^Patient already has a #{agent} reaction entered.  No duplicates allowed.")
    result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
    refute result[:success]
    assert_equal :duplicate, result[:error]
    assert_equal "-1^Patient already has a #{agent} reaction entered.  No duplicates allowed.",
                 result[:message]
  end

  def test_save_maps_lock_failure
    seed_save_reply(LOCK_REPLY)
    result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
    refute result[:success]
    assert_equal :locked, result[:error]
    assert_equal LOCK_REPLY, result[:message]
  end

  def test_save_maps_unknown_minus_one_as_rejected
    seed_save_reply("-1^synthetic broker rejection")
    result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
    refute result[:success]
    assert_equal :rejected, result[:error]
    assert_equal "-1^synthetic broker rejection", result[:message]
  end

  def test_save_empty_replies_fail_closed
    [ "", [], nil ].each do |reply|
      RpmsRpc.reset!
      with_broker_reply(reply) do
        result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
        refute result[:success], "reply #{reply.inspect} must not succeed"
        assert_equal :empty_reply, result[:error]
      end
    end
  end

  def test_save_malformed_replies_fail_closed
    malformed = %w[1 0^abc OK] + [ [ "0", "extra" ], 0, :zero ]
    malformed.each do |reply|
      RpmsRpc.reset!
      with_broker_reply(reply) do
        result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
        refute result[:success], "reply #{reply.inspect} must not succeed"
        assert_equal :malformed_reply, result[:error]
      end
    end
  end

  def test_save_reads_one_element_array_reply_as_single_line
    agent = SYNTH_ALLERGY[:agent]
    cases = [
      [ [ "0" ], true, nil, nil ],
      [ [ "0^4242" ], true, 4242, nil ],
      [ [ "-1^Patient already has a #{agent} reaction entered.  No duplicates allowed." ],
        false, nil, :duplicate ],
      [ [ LOCK_REPLY ], false, nil, :locked ],
      [ [ "-1^Patient has active allergies - can't mark as NKA" ], false, nil, :active_allergies ],
      [ [ "-1^Unable to update assessment - try again." ], false, nil, :assessment_update_failed ],
      [ [ "-1^synthetic broker rejection" ], false, nil, :rejected ]
    ]
    cases.each do |reply, success, note_ien, error|
      RpmsRpc.reset!
      with_broker_reply(reply) do
        result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
        assert_equal success, result[:success], "reply #{reply.inspect}"
        if success
          assert_equal note_ien, result[:note_ien]
        else
          assert_equal error, result[:error]
          assert_equal reply.first, result[:message]
        end
      end
    end
  end

  def test_save_accepts_valid_fixture_formats
    seed_save_reply("0")
    result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
    assert result[:success]
    assert_equal expected_edited(SYNTH_ALLERGY), save_call[:params][2]
  end

  def test_save_rejects_caret_or_control_in_reaction_date_and_severity_without_rpc
    [
      [ :reaction_date, "3261015^1" ],
      [ :reaction_date, "3261015\x01" ],
      [ :severity, "MOD^ERATE" ],
      [ :severity, "MOD\x7f" ]
    ].each do |field, value|
      assert_invalid_value_refusal(field, SYNTH_ALLERGY.merge(field => value))
    end
  end

  def test_save_rejects_invalid_reaction_date_format_without_rpc
    %w[yesterday 2026-10-15 326101].each do |value|
      assert_invalid_value_refusal(:reaction_date, SYNTH_ALLERGY.merge(reaction_date: value))
    end
  end

  def test_save_rejects_invalid_agent_pointer_format_without_rpc
    %w[
      garbage
      125
      125;PSNDF(50.6
      0;GMRD(120.82,
      45;PSDRUG(1
      45;psdrug(
    ].each do |value|
      assert_invalid_value_refusal(:agent_pointer, SYNTH_ALLERGY.merge(agent_pointer: value))
    end
  end

  def test_save_accepts_stock_agent_pointer_roots_including_local_psdrug
    VALID_AGENT_POINTERS.each do |pointer|
      RpmsRpc.reset!
      seed_save_reply("0")
      attrs = SYNTH_ALLERGY.merge(agent_pointer: pointer)
      assert RpmsRpc::Allergy.save(DFN, attrs)[:success], "agent_pointer #{pointer.inspect}"
      assert_equal pointer, save_call[:params][2]["GMRAGNT"].split("^", 2).last
    end
  end

  def test_save_dispatches_blank_reaction_date_without_gmrardt_in_oredited
    seed_save_reply("0")
    attrs = SYNTH_ALLERGY.merge(reaction_date: "")
    result = RpmsRpc::Allergy.save(DFN, attrs)
    assert result[:success]
    edited = save_call[:params][2]
    refute edited.key?("GMRARDT"), "blank reaction_date is absent on the wire (GMRAGUI1.m:137 $G)"
  end

  def test_save_dispatches_blank_severity_without_gmrasevr_in_oredited
    seed_save_reply("0")
    attrs = SYNTH_ALLERGY.merge(severity: "")
    result = RpmsRpc::Allergy.save(DFN, attrs)
    assert result[:success]
    edited = save_call[:params][2]
    refute edited.key?("GMRASEVR"), "blank severity is absent on the wire (GMRAGUI1.m:137 $G)"
  end

  def test_save_rejects_invalid_severity_without_rpc
    %w[MODERATE X 4 02].each do |value|
      assert_invalid_value_refusal(:severity, SYNTH_ALLERGY.merge(severity: value))
    end
  end

  def test_save_accepts_orwdal32_severity_codes
    %w[1 2 3].each do |value|
      seed_save_reply("0")
      attrs = SYNTH_ALLERGY.merge(severity: value)
      assert RpmsRpc::Allergy.save(DFN, attrs)[:success], "severity #{value.inspect}"
      assert_equal value, save_call[:params][2]["GMRASEVR"]
    end
  end

  def test_save_accepts_integer_severity_one_two_three
    [ 1, 2, 3 ].each do |value|
      RpmsRpc.reset!
      seed_save_reply("0")
      attrs = SYNTH_ALLERGY.merge(severity: value)
      assert RpmsRpc::Allergy.save(DFN, attrs)[:success], "severity #{value.inspect}"
      assert_equal value.to_s, save_call[:params][2]["GMRASEVR"]
    end
  end

  def test_save_rejects_integer_severity_zero_and_four_without_rpc
    [ 0, 4 ].each do |value|
      assert_invalid_value_refusal(:severity, SYNTH_ALLERGY.merge(severity: value))
    end
  end

  def test_save_rejects_invalid_symptom_ien_without_rpc
    %w[abc 010 ft].each do |ien|
      attrs = SYNTH_ALLERGY.merge(symptoms: [ { ien: ien, text: "RASH", date: "3261015" } ])
      assert_invalid_value_refusal(:symptoms, attrs)
    end
  end

  def test_save_rejects_symptom_without_non_blank_text_without_rpc
    [
      [ { ien: "10" } ],
      [ { ien: "FT" } ],
      [ { ien: "FT", text: "" } ]
    ].each do |symptoms|
      assert_invalid_value_refusal(:symptoms, SYNTH_ALLERGY.merge(symptoms: symptoms))
    end
  end

  # :text must contain visible characters per Allergy.visible? (not only whitespace or invisible).
  def test_save_rejects_symptom_text_without_visible_content_without_rpc
    whitespace = [
      [ { text: "   " } ],
      [ { ien: "10", text: "  " } ]
    ]
    invisible = [
      [ { text: "\u200B" } ],
      [ { text: "\u00A0" } ],
      [ { text: "\u00AD" } ]
    ]
    (whitespace + invisible).each do |symptoms|
      assert_invalid_value_refusal(:symptoms, SYNTH_ALLERGY.merge(symptoms: symptoms))
    end
  end

  def test_save_dispatches_symptoms_whose_text_is_visible
    cases = [
      [ [ { ien: "10", text: "RASH" } ], "10^RASH^" ],
      [ [ { ien: "FT", text: "ITCHY EYES" } ], "FT^ITCHY EYES^" ]
    ]
    cases.each do |symptoms, wire|
      RpmsRpc.reset!
      seed_save_reply("0")
      attrs = SYNTH_ALLERGY.merge(symptoms: symptoms)
      result = RpmsRpc::Allergy.save(DFN, attrs)
      assert result[:success], symptoms.inspect
      assert_equal wire, save_call[:params][2][[ "GMRASYMP", 1 ]]
    end
  end

  def test_save_names_reaction_date_caret_before_invalid_type
    RpmsRpc.mock!
    attrs = SYNTH_ALLERGY.merge(reaction_date: "3261015^1", type: "ZZ")
    result = RpmsRpc::Allergy.save(DFN, attrs)
    expected = { success: false, error: :invalid_value, message: "invalid reaction_date" }
    assert_equal expected, result
    assert_empty RpmsRpc.client.received_calls
  end

  def test_save_names_severity_caret_before_invalid_type
    RpmsRpc.mock!
    attrs = SYNTH_ALLERGY.merge(severity: "1^2", type: "ZZ")
    result = RpmsRpc::Allergy.save(DFN, attrs)
    expected = { success: false, error: :invalid_value, message: "invalid severity" }
    assert_equal expected, result
    assert_empty RpmsRpc.client.received_calls
  end

  def test_save_names_agent_caret_before_later_format_faults
    cases = [
      { observed_or_historical: "x" },
      { originator: "abc" },
      { severity: "4" }
    ]
    cases.each do |override|
      RpmsRpc.mock!
      attrs = SYNTH_ALLERGY.merge(agent: "PEN^ICILLIN", **override)
      result = RpmsRpc::Allergy.save(DFN, attrs)
      expected = { success: false, error: :invalid_value, message: "invalid agent" }
      assert_equal expected, result, override.inspect
      assert_empty RpmsRpc.client.received_calls, override.inspect
    end
  end

  def test_save_rejects_invalid_symptom_date_without_rpc
    %w[yesterday 2026-10-15].each do |date|
      attrs = SYNTH_ALLERGY.merge(symptoms: [ { ien: "10", text: "RASH", date: date } ])
      assert_invalid_value_refusal(:symptoms, attrs)
    end
  end

  def test_save_accepts_valid_symptom_shapes
    cases = [
      [ [ { ien: "10", text: "RASH", date: "3261015" } ], "10^RASH^3261015" ],
      [ [ { ien: "FT", text: "ITCHY EYES" } ], "FT^ITCHY EYES^" ],
      [ [ { ien: "10", text: "RASH" } ], "10^RASH^" ]
    ]
    cases.each do |symptoms, wire|
      RpmsRpc.reset!
      seed_save_reply("0")
      attrs = SYNTH_ALLERGY.merge(symptoms: symptoms)
      assert RpmsRpc::Allergy.save(DFN, attrs)[:success], symptoms.inspect
      assert_equal wire, save_call[:params][2][[ "GMRASYMP", 1 ]]
    end
  end

  def test_save_dispatches_symptom_with_blank_date
    seed_save_reply("0")
    attrs = SYNTH_ALLERGY.merge(symptoms: [ { ien: "10", text: "RASH", date: "" } ])
    result = RpmsRpc::Allergy.save(DFN, attrs)
    assert result[:success]
    assert_equal "10^RASH^", save_call[:params][2][[ "GMRASYMP", 1 ]]
  end

  def test_save_dispatches_integer_symptom_ien
    seed_save_reply("0")
    attrs = SYNTH_ALLERGY.merge(symptoms: [ { ien: 10, text: "RASH", date: "3261015" } ])
    result = RpmsRpc::Allergy.save(DFN, attrs)
    assert result[:success]
    assert_equal "10^RASH^3261015", save_call[:params][2][[ "GMRASYMP", 1 ]]
  end

  def test_save_caret_in_agent_is_reported_before_invalid_symptom_date
    RpmsRpc.mock!
    attrs = SYNTH_ALLERGY.merge(
      agent: "PEN^X",
      symptoms: [ { ien: "10", text: "RASH", date: "yesterday" } ]
    )
    result = RpmsRpc::Allergy.save(DFN, attrs)
    expected = { success: false, error: :invalid_value, message: "invalid agent" }
    assert_equal expected, result
    assert_empty RpmsRpc.client.received_calls
  end

  def test_save_rejects_invalid_originated_at_format_without_rpc
    %w[yesterday 2026-10-15 326101].each do |value|
      assert_invalid_value_refusal(:originated_at, SYNTH_ALLERGY.merge(originated_at: value))
    end
  end

  def test_save_rejects_invalid_type_without_rpc
    [ "ZZ", "DD", 5, "" ].each do |value|
      assert_invalid_value_refusal(:type, SYNTH_ALLERGY.merge(type: value))
    end
  end

  def test_save_accepts_valid_type_letters
    %w[D F O DF DFO].each do |value|
      seed_save_reply("0")
      attrs = SYNTH_ALLERGY.merge(type: value)
      assert RpmsRpc::Allergy.save(DFN, attrs)[:success], "type #{value.inspect}"
      assert_equal value, save_call[:params][2]["GMRATYPE"]
    end
  end

  def test_save_rejects_invalid_nature_without_rpc
    assert_invalid_value_refusal(:nature, SYNTH_ALLERGY.merge(nature: "Q"))
  end

  def test_save_parses_one_element_reply_with_recordset_framing_bytes
    [
      [ [ "0\x1E" ], nil ],
      [ [ "0^4242\x1E\x1F" ], 4242 ]
    ].each do |reply, note_ien|
      RpmsRpc.reset!
      with_broker_reply(reply) do
        result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
        assert result[:success], "reply #{reply.inspect}"
        assert_equal note_ien, result[:note_ien]
      end
    end
  end

  def test_save_rejects_caret_or_control_in_list_values_without_rpc
    caret = "PEN^999;PS(50.416,"
    control = "PEN\x01ICILLIN"
    scalar_fields = {
      agent: caret,
      agent_pointer: caret,
      type: "D^X",
      nature: "A\x7f",
      originator: "42^1",
      originated_at: "3261015\x01",
      observed_or_historical: "o\x00"
    }
    scalar_fields.each do |field, value|
      RpmsRpc.mock!
      attrs = SYNTH_ALLERGY.merge(field => value)
      refute RpmsRpc::Allergy.save(DFN, attrs)[:success]
      assert_empty RpmsRpc.client.received_calls, "caret/control in #{field}"
    end

    RpmsRpc.mock!
    attrs = SYNTH_ALLERGY.merge(comments: [ "line\x01two" ])
    refute RpmsRpc::Allergy.save(DFN, attrs)[:success]
    assert_empty RpmsRpc.client.received_calls

    %i[ien text date].each do |sym_field|
      RpmsRpc.mock!
      symptom = { ien: "10", text: "RASH", date: "3261015" }
      symptom[sym_field] = case sym_field
      when :ien then "1^0"
      when :text then "RA^SH"
      when :date then "3261015\x01"
      end
      attrs = SYNTH_ALLERGY.merge(symptoms: [ symptom ])
      refute RpmsRpc::Allergy.save(DFN, attrs)[:success]
      assert_empty RpmsRpc.client.received_calls, "caret/control in symptom #{sym_field}"
    end
  end

  def test_save_rejects_invalid_symptoms_or_comments_shape_without_rpc
    [
      { symptoms: [ nil ] },
      { symptoms: "RASH" },
      { comments: "one" },
      { symptoms: [ { ien: "", text: "RASH", date: "3261015" } ] }
    ].each do |override|
      RpmsRpc.mock!
      attrs = SYNTH_ALLERGY.merge(override)
      refute RpmsRpc::Allergy.save(DFN, attrs)[:success]
      assert_empty RpmsRpc.client.received_calls, override.inspect
    end
  end

  def test_save_rejects_invalid_observed_or_historical_without_rpc
    %w[O H x].each do |value|
      RpmsRpc.mock!
      attrs = SYNTH_ALLERGY.merge(observed_or_historical: value)
      refute RpmsRpc::Allergy.save(DFN, attrs)[:success]
      assert_empty RpmsRpc.client.received_calls, "observed_or_historical=#{value.inspect}"
    end
  end

  def test_save_rejects_invalid_originator_without_rpc
    %w[0 -1 abc 12.5].each do |value|
      RpmsRpc.mock!
      attrs = SYNTH_ALLERGY.merge(originator: value)
      refute RpmsRpc::Allergy.save(DFN, attrs)[:success]
      assert_empty RpmsRpc.client.received_calls, "originator=#{value.inspect}"
    end
  end

  def test_save_rejects_invalid_dfn_without_rpc
    [ nil, "", "0", "abc", "12abc" ].each do |dfn|
      RpmsRpc.mock!
      result = RpmsRpc::Allergy.save(dfn, SYNTH_ALLERGY)
      refute result[:success]
      assert_empty RpmsRpc.client.received_calls
    end
  end

  def test_save_rejects_missing_required_fields_without_rpc
    %i[agent agent_pointer type nature originator originated_at observed_or_historical].each do |field|
      RpmsRpc.mock!
      attrs = SYNTH_ALLERGY.dup
      attrs.delete(field)
      result = RpmsRpc::Allergy.save(DFN, attrs)
      refute result[:success]
      assert_empty RpmsRpc.client.received_calls
    end
  end

  # --- no known allergies (GMRANKA^GMRAGUI1 NKA path) -----------------------

  def test_no_known_allergies_dispatches_nka_list_param
    seed_save_reply("0")
    RpmsRpc::Allergy.no_known_allergies(DFN)

    call = save_call
    assert_equal [ "", DFN, { "GMRANKA" => "YES" } ], call[:params]
  end

  def test_no_known_allergies_success_on_zero
    seed_save_reply("0")
    result = RpmsRpc::Allergy.no_known_allergies(DFN)
    assert result[:success]
    assert_nil result[:note_ien] if result.key?(:note_ien)
  end

  def test_no_known_allergies_maps_active_allergies_failure
    seed_save_reply("-1^Patient has active allergies - can't mark as NKA")
    result = RpmsRpc::Allergy.no_known_allergies(DFN)
    refute result[:success]
    assert_equal :active_allergies, result[:error]
  end

  def test_no_known_allergies_maps_assessment_update_failure
    seed_save_reply("-1^Unable to update assessment - try again.")
    result = RpmsRpc::Allergy.no_known_allergies(DFN)
    refute result[:success]
    assert_equal :assessment_update_failed, result[:error]
  end

  def test_no_known_allergies_maps_lock_failure
    seed_save_reply(LOCK_REPLY)
    result = RpmsRpc::Allergy.no_known_allergies(DFN)
    refute result[:success]
    assert_equal :locked, result[:error]
  end

  def test_no_known_allergies_reads_one_element_array_reply_as_single_line
    cases = [
      [ [ "0" ], true, nil, nil ],
      [ [ "-1^Patient has active allergies - can't mark as NKA" ], false, nil, :active_allergies ],
      [ [ "-1^Unable to update assessment - try again." ], false, nil, :assessment_update_failed ],
      [ [ LOCK_REPLY ], false, nil, :locked ]
    ]
    cases.each do |reply, success, _note_ien, error|
      RpmsRpc.reset!
      with_broker_reply(reply) do
        result = RpmsRpc::Allergy.no_known_allergies(DFN)
        assert_equal success, result[:success], "reply #{reply.inspect}"
        assert_equal error, result[:error] unless success
      end
    end
  end

  def test_no_known_allergies_malformed_replies_fail_closed
    [ [ "0", "1" ], 0, :zero ].each do |reply|
      RpmsRpc.reset!
      with_broker_reply(reply) do
        result = RpmsRpc::Allergy.no_known_allergies(DFN)
        refute result[:success]
        assert_equal :malformed_reply, result[:error]
      end
    end
  end

  def test_no_known_allergies_rejects_invalid_dfn_without_rpc
    RpmsRpc.mock!
    refute RpmsRpc::Allergy.no_known_allergies(nil)[:success]
    assert_empty RpmsRpc.client.received_calls
  end

  # --- safety / compatibility ------------------------------------------------

  def test_neither_write_path_uses_ddr_filer
    seed_save_reply("0")
    RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
    RpmsRpc::Allergy.no_known_allergies(DFN)
    refute RpmsRpc.client.received_calls.any? { |c| c[:rpc] == "DDR FILER" }
  end

  def test_retry_safety_classifies_both_writes_as_non_idempotent
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(RpmsRpc::Allergy, :save)
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(RpmsRpc::Allergy, :no_known_allergies)
  end

  def test_required_rpcs_lists_save_allergy_under_allergy_module
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    assert_includes doc.fetch("modules").fetch("RpmsRpc::Allergy"), RPC
  end

  private

  def assert_invalid_value_refusal(field, attrs)
    RpmsRpc.mock!
    result = RpmsRpc::Allergy.save(DFN, attrs)
    expected = { success: false, error: :invalid_value, message: "invalid #{field}" }
    unless result == expected
      rpc_sent = !RpmsRpc.client.received_calls.empty?
      flunk "expected #{expected.inspect}, got #{result.inspect} (RPC sent: #{rpc_sent})"
    end
    assert_empty RpmsRpc.client.received_calls, "invalid #{field}"
  end

  def save_call
    RpmsRpc.client.received_calls.find { |c| c[:rpc] == RPC }
  end

  # Two-level GMRASYMP / GMRACMTS subscripts (GMRAGUI1.m:116-118) use the
  # transport's array-key encoding (CiaClient#m_subscript / XwbClient#m_subscript).
  def expected_edited(allergy)
    edited = {
      "GMRAGNT" => "#{allergy[:agent]}^#{allergy[:agent_pointer]}",
      "GMRATYPE" => allergy[:type],
      "GMRANATR" => allergy[:nature],
      "GMRAORIG" => allergy[:originator].to_s,
      "GMRAORDT" => allergy[:originated_at],
      "GMRAOBHX" => allergy[:observed_or_historical]
    }
    allergy[:symptoms]&.each_with_index do |sym, idx|
      edited[[ "GMRASYMP", idx + 1 ]] = "#{sym[:ien]}^#{sym[:text]}^#{sym[:date]}"
    end
    allergy[:comments]&.each_with_index do |line, idx|
      edited[[ "GMRACMTS", idx + 1 ]] = line
    end
    edited["GMRARDT"] = allergy[:reaction_date] if allergy[:reaction_date]
    edited["GMRASEVR"] = allergy[:severity] if allergy[:severity]
    edited
  end

  def seed_save_reply(value)
    RpmsRpc.mock!
    scalars = RpmsRpc.client.instance_variable_get(:@scalars)
    scalars[RPC] = { "" => broker_reply(value) }
  end

  # Live XWB and CIA clients return ORY as an Array of lines (["0"], ["0^4242"], …).
  def broker_reply(value)
    case value
    when Array then value
    when nil then nil
    else [ value ]
    end
  end

  def with_broker_reply(reply)
    shaped = broker_reply(reply)
    client = RpmsRpc::MockClient.new
    client.define_singleton_method(:call_rpc) do |rpc_name, *params|
      received_calls << { rpc: rpc_name, params: params, context: current_context }
      return shaped if rpc_name == RPC

      ""
    end
    RpmsRpc.configure { |cfg| cfg.client = client }
    yield
  end
end
