# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require "rpms_rpc/api/allergy"
require "rpms_rpc/retry_safety"
require_relative "../captured_replies"

# ORWDAL32 SAVE ALLERGY: EDITSAVE^ORWDAL32 -> UPDATE^GMRAGUI1 / NKA^GMRAGUI1.
# The replies are the build's (test/fixtures/captured_replies/allergy-save.yml):
# Allergy.save and .no_known_allergies, run as PROFILE,MD on a throwaway
# container, recorded as flows and replayed through CiaClient. A guard test
# answers nothing and asserts nothing reached the wire.
#
# Not captured, so not tested here: a reply that names a progress note
# ("0^IEN"), the busy-lock reply (under the YDB CIA broker a busy lock answers
# 0 and files nothing, openrpms#1121), and "Unable to update assessment".
class AllergySaveTest < Minitest::Test
  SLUG = "allergy-save"
  RPC = "ORWDAL32 SAVE ALLERGY"
  DFN = "3"

  # The allergy the capture filed: the build's own agent and symptom entries.
  SYNTH_ALLERGY = {
    agent: "ABALONE",
    agent_pointer: "125;GMRD(120.82,",
    type: "F",
    nature: "A",
    originator: "206",
    originated_at: "3261109.12",
    observed_or_historical: "o",
    symptoms: [ { ien: "133", text: "RASH", date: "3261109" } ],
    comments: [ "Synthetic capture comment." ],
    reaction_date: "3261109",
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

  # Answers nil for every call, for the empty-reply path no capture holds.
  class NilReplyClient
    def call_rpc(*) = nil
  end

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  # A client that answers the named flow's replies, as the build sent them.
  def replay_flow(name) = replay(CapturedReplies.flow_script(SLUG, name))

  # A client that answers each save with the build's success reply, for tests
  # that check the frame a valid input sends.
  def replay_success(times = 1)
    reply = CapturedReplies.flow(SLUG, "save_new").first.fetch("raw_return").b
    replay(RPC => Array.new(times) { reply })
  end

  # --- wiring (EDITSAVE^ORWDAL32: ORALIEN, ORDFN, OREDITED list) ------------

  # The frame the gem sent is the one the build filed the allergy from.
  def test_save_sends_the_frame_the_build_filed
    client = replay_flow("save_new")

    RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)

    assert_equal CapturedReplies.flow_calls(SLUG, "save_new"), client.calls.map { |c| [ c[:rpc], c[:params] ] }
    assert_equal [ "", DFN, expected_edited(SYNTH_ALLERGY) ], client.calls.first[:params],
                 "ORY is the broker return; client params are ORALIEN, ORDFN, OREDITED"
  end

  def test_save_success_without_progress_note
    replay_flow("save_new")

    assert_equal({ success: true, note_ien: nil }, RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY))
  end

  # The allergy the save filed reads back through ORQQAL LIST.
  def test_the_saved_allergy_reads_back
    replay_flow("assessment_after")

    assessment = RpmsRpc::Allergy.assessment(DFN)

    assert assessment[:assessed]
    refute assessment[:nka]
    assert_equal [ { ien: "3", allergen: "ABALONE", severity: "MODERATE", signs: "RASH", altered: false } ],
                 assessment[:allergies]
  end

  def test_save_maps_duplicate_failure
    replay_flow("save_duplicate")

    result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)

    refute result[:success]
    assert_equal :duplicate, result[:error]
    assert_equal "-1^Patient already has a ABALONE reaction entered.  No duplicates allowed.", result[:message]
  end

  def test_save_empty_reply_fails_closed
    RpmsRpc.configure { |cfg| cfg.client = NilReplyClient.new }

    result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)

    refute result[:success]
    assert_equal :empty_reply, result[:error]
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
      client = replay_success
      attrs = SYNTH_ALLERGY.merge(agent_pointer: pointer)
      assert RpmsRpc::Allergy.save(DFN, attrs)[:success], "agent_pointer #{pointer.inspect}"
      assert_equal pointer, client.calls.first[:params][2]["GMRAGNT"].split("^", 2).last
    end
  end

  def test_save_dispatches_blank_reaction_date_without_gmrardt_in_oredited
    client = replay_success
    assert RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY.merge(reaction_date: ""))[:success]
    refute client.calls.first[:params][2].key?("GMRARDT"), "blank reaction_date is absent on the wire (GMRAGUI1.m:137 $G)"
  end

  def test_save_dispatches_blank_severity_without_gmrasevr_in_oredited
    client = replay_success
    assert RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY.merge(severity: ""))[:success]
    refute client.calls.first[:params][2].key?("GMRASEVR"), "blank severity is absent on the wire (GMRAGUI1.m:137 $G)"
  end

  def test_save_rejects_invalid_severity_without_rpc
    %w[MODERATE X 4 02].each do |value|
      assert_invalid_value_refusal(:severity, SYNTH_ALLERGY.merge(severity: value))
    end
  end

  def test_save_accepts_orwdal32_severity_codes_as_strings_and_integers
    [ "1", "2", "3", 1, 2, 3 ].each do |value|
      client = replay_success
      assert RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY.merge(severity: value))[:success], "severity #{value.inspect}"
      assert_equal value.to_s, client.calls.first[:params][2]["GMRASEVR"]
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
    [
      [ { text: "   " } ],
      [ { ien: "10", text: "  " } ],
      [ { text: "​" } ],
      [ { text: " " } ],
      [ { text: "­" } ]
    ].each do |symptoms|
      assert_invalid_value_refusal(:symptoms, SYNTH_ALLERGY.merge(symptoms: symptoms))
    end
  end

  def test_save_dispatches_valid_symptom_shapes
    [
      [ [ { ien: "133", text: "RASH", date: "3261109" } ], "133^RASH^3261109" ],
      [ [ { ien: "FT", text: "ITCHY EYES" } ], "FT^ITCHY EYES^" ],
      [ [ { ien: "133", text: "RASH" } ], "133^RASH^" ],
      [ [ { ien: "133", text: "RASH", date: "" } ], "133^RASH^" ],
      [ [ { ien: 133, text: "RASH", date: "3261109" } ], "133^RASH^3261109" ]
    ].each do |symptoms, wire|
      client = replay_success
      assert RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY.merge(symptoms: symptoms))[:success], symptoms.inspect
      assert_equal wire, client.calls.first[:params][2][[ "GMRASYMP", 1 ]]
    end
  end

  def test_save_names_reaction_date_caret_before_invalid_type
    assert_refused_as(:reaction_date, SYNTH_ALLERGY.merge(reaction_date: "3261015^1", type: "ZZ"))
  end

  def test_save_names_severity_caret_before_invalid_type
    assert_refused_as(:severity, SYNTH_ALLERGY.merge(severity: "1^2", type: "ZZ"))
  end

  def test_save_names_agent_caret_before_later_format_faults
    [
      { observed_or_historical: "x" },
      { originator: "abc" },
      { severity: "4" },
      { symptoms: [ { ien: "133", text: "RASH", date: "yesterday" } ] }
    ].each do |override|
      assert_refused_as(:agent, SYNTH_ALLERGY.merge(agent: "PEN^ICILLIN", **override))
    end
  end

  def test_save_rejects_invalid_symptom_date_without_rpc
    %w[yesterday 2026-10-15].each do |date|
      attrs = SYNTH_ALLERGY.merge(symptoms: [ { ien: "133", text: "RASH", date: date } ])
      assert_invalid_value_refusal(:symptoms, attrs)
    end
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
      client = replay_success
      assert RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY.merge(type: value))[:success], "type #{value.inspect}"
      assert_equal value, client.calls.first[:params][2]["GMRATYPE"]
    end
  end

  def test_save_rejects_invalid_nature_without_rpc
    assert_invalid_value_refusal(:nature, SYNTH_ALLERGY.merge(nature: "Q"))
  end

  def test_save_rejects_caret_or_control_in_list_values_without_rpc
    caret = "PEN^999;PS(50.416,"
    {
      agent: caret,
      agent_pointer: caret,
      type: "D^X",
      nature: "A\x7f",
      originator: "42^1",
      originated_at: "3261015\x01",
      observed_or_historical: "o\x00"
    }.each do |field, value|
      assert_no_wire(SYNTH_ALLERGY.merge(field => value), "caret/control in #{field}")
    end

    assert_no_wire(SYNTH_ALLERGY.merge(comments: [ "line\x01two" ]), "control in a comment")

    { ien: "1^0", text: "RA^SH", date: "3261015\x01" }.each do |sym_field, value|
      symptom = { ien: "133", text: "RASH", date: "3261109" }.merge(sym_field => value)
      assert_no_wire(SYNTH_ALLERGY.merge(symptoms: [ symptom ]), "caret/control in symptom #{sym_field}")
    end
  end

  def test_save_rejects_invalid_symptoms_or_comments_shape_without_rpc
    [
      { symptoms: [ nil ] },
      { symptoms: "RASH" },
      { comments: "one" },
      { symptoms: [ { ien: "", text: "RASH", date: "3261015" } ] }
    ].each do |override|
      assert_no_wire(SYNTH_ALLERGY.merge(override), override.inspect)
    end
  end

  def test_save_rejects_invalid_observed_or_historical_without_rpc
    %w[O H x].each do |value|
      assert_no_wire(SYNTH_ALLERGY.merge(observed_or_historical: value), "observed_or_historical=#{value.inspect}")
    end
  end

  def test_save_rejects_invalid_originator_without_rpc
    %w[0 -1 abc 12.5].each do |value|
      assert_no_wire(SYNTH_ALLERGY.merge(originator: value), "originator=#{value.inspect}")
    end
  end

  def test_save_rejects_invalid_dfn_without_rpc
    [ nil, "", "0", "abc", "12abc" ].each do |dfn|
      client = replay({})
      refute RpmsRpc::Allergy.save(dfn, SYNTH_ALLERGY)[:success]
      assert_empty client.calls, "dfn=#{dfn.inspect}"
    end
  end

  def test_save_rejects_missing_required_fields_without_rpc
    %i[agent agent_pointer type nature originator originated_at observed_or_historical].each do |field|
      attrs = SYNTH_ALLERGY.dup
      attrs.delete(field)
      assert_no_wire(attrs, "missing #{field}")
    end
  end

  # --- no known allergies (NKA^GMRAGUI1) ------------------------------------

  def test_no_known_allergies_sends_the_frame_the_build_filed
    client = replay_flow("nka")

    RpmsRpc::Allergy.no_known_allergies("5")

    assert_equal CapturedReplies.flow_calls(SLUG, "nka"), client.calls.map { |c| [ c[:rpc], c[:params] ] }
    assert_equal [ "", "5", { "GMRANKA" => "YES" } ], client.calls.first[:params]
  end

  def test_no_known_allergies_success_on_zero
    replay_flow("nka")

    result = RpmsRpc::Allergy.no_known_allergies("5")

    assert result[:success]
    assert_nil result[:note_ien]
  end

  # NKA^GMRAGUI1 answers 0 again for a patient already NKA.
  def test_no_known_allergies_on_a_patient_already_nka_succeeds
    replay_flow("nka_again")

    assert RpmsRpc::Allergy.no_known_allergies("5")[:success]
  end

  def test_the_nka_assessment_reads_back
    replay_flow("assessment_after")
    RpmsRpc::Allergy.assessment(DFN)

    assert_equal({ assessed: true, nka: true, allergies: [] }, RpmsRpc::Allergy.assessment("5"))
  end

  def test_no_known_allergies_maps_active_allergies_failure
    replay_flow("nka_with_allergies")

    result = RpmsRpc::Allergy.no_known_allergies(DFN)

    refute result[:success]
    assert_equal :active_allergies, result[:error]
    assert_equal "-1^Patient has active allergies - can't mark as NKA", result[:message]
  end

  def test_no_known_allergies_empty_reply_fails_closed
    RpmsRpc.configure { |cfg| cfg.client = NilReplyClient.new }

    result = RpmsRpc::Allergy.no_known_allergies(DFN)

    refute result[:success]
    assert_equal :empty_reply, result[:error]
  end

  def test_no_known_allergies_rejects_invalid_dfn_without_rpc
    client = replay({})

    refute RpmsRpc::Allergy.no_known_allergies(nil)[:success]
    assert_empty client.calls
  end

  # --- safety / compatibility ------------------------------------------------

  def test_neither_write_path_uses_ddr_filer
    client = replay(RPC => [ CapturedReplies.flow(SLUG, "save_new").first.fetch("raw_return").b,
                             CapturedReplies.flow(SLUG, "nka").first.fetch("raw_return").b ])

    RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY)
    RpmsRpc::Allergy.no_known_allergies("5")

    assert_equal [ RPC, RPC ], client.rpcs_called
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

  # The input is refused as the named field, before anything is sent.
  def assert_refused_as(field, attrs)
    client = replay({})
    result = RpmsRpc::Allergy.save(DFN, attrs)
    assert_equal({ success: false, error: :invalid_value, message: "invalid #{field}" }, result)
    assert_empty client.calls, "invalid #{field}"
  end
  alias assert_invalid_value_refusal assert_refused_as

  # The input is refused, whatever the field, before anything is sent.
  def assert_no_wire(attrs, label)
    client = replay({})
    refute RpmsRpc::Allergy.save(DFN, attrs)[:success], label
    assert_empty client.calls, label
  end

  # Two-level GMRASYMP / GMRACMTS subscripts (GMRAGUI1.m:116-118) use the
  # transport's array-key encoding (CiaClient#m_subscript).
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
end
