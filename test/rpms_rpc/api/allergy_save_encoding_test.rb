# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/allergy"

# Issue #485 — Allergy.save must fail closed on invalid text encodings and
# invisible-only free text before ORWDAL32 SAVE ALLERGY is sent.
class AllergySaveEncodingTest < Minitest::Test
  DFN = "8791"
  RPC = "ORWDAL32 SAVE ALLERGY"

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

  INVISIBLE_ONLY_AGENTS = [
    "",
    " ",
    "\u200B",
    "\u00A0\u200B"
  ].freeze

  NON_VISIBLE_COMMENT_LINES = [
    "   ",
    "\u200B",
    "\u00A0"
  ].freeze

  def teardown
    RpmsRpc.reset!
  end

  def test_save_invalid_utf8_on_every_validated_string_field_returns_invalid_value_without_rpc
    cases = scalar_invalid_utf8_cases +
            symptom_invalid_utf8_cases +
            comment_invalid_utf8_cases
    cases.each do |field, attrs|
      assert_invalid_value_refusal(field, SYNTH_ALLERGY.merge(attrs))
    end
  end

  def test_save_binary_high_bytes_on_every_validated_string_field_returns_invalid_value_without_rpc
    cases = scalar_binary_cases + symptom_binary_cases + comment_binary_cases
    cases.each do |field, attrs|
      assert_invalid_value_refusal(field, SYNTH_ALLERGY.merge(attrs))
    end
  end

  def test_save_rejects_invisible_only_agents_as_invalid_value_without_rpc
    INVISIBLE_ONLY_AGENTS.each do |agent|
      assert_invalid_value_refusal(:agent, SYNTH_ALLERGY.merge(agent: agent))
    end
  end

  def test_save_rejects_whitespace_or_invisible_only_comment_lines_without_rpc
    NON_VISIBLE_COMMENT_LINES.each do |line|
      assert_invalid_value_refusal(:comments, SYNTH_ALLERGY.merge(comments: [ line ]))
    end
  end

  # GMRACMTS(n) is read whole in ADCOM^GMRAGUI1 (GMRAGUI1.m:59-60) and filed via ^DIWP;
  # EDITSAVE^ORWDAL32 merges OREDITED without splitting comment text (ORWDAL32.m:137-138).
  def test_save_accepts_caret_in_comment_and_sends_verbatim_on_wire
    seed_save_reply("0")
    comment = "BP 120^80"
    attrs = SYNTH_ALLERGY.merge(comments: [ comment ])
    result = RpmsRpc::Allergy.save(DFN, attrs)
    assert result[:success], result.inspect
    assert_equal comment, save_call[:params][2][[ "GMRACMTS", 1 ]]
  end

  def test_save_still_rejects_control_characters_in_comment_lines_without_rpc
    assert_invalid_value_refusal(:comment, SYNTH_ALLERGY.merge(comments: [ "line\x01two" ]))
  end

  private

  def scalar_invalid_utf8_cases
    [
      [ :agent, { agent: invalid_utf8("PEN") } ],
      [ :agent_pointer, { agent_pointer: invalid_utf8("125;PSNDF(50.6,") } ],
      [ :type, { type: invalid_utf8("D") } ],
      [ :nature, { nature: invalid_utf8("A") } ],
      [ :originator, { originator: invalid_utf8("42") } ],
      [ :originated_at, { originated_at: invalid_utf8("3261015.1045") } ],
      [ :observed_or_historical, { observed_or_historical: invalid_utf8("o") } ],
      [ :reaction_date, { reaction_date: invalid_utf8("3261015") } ],
      [ :severity, { severity: invalid_utf8("2") } ]
    ]
  end

  def scalar_binary_cases
    [
      [ :agent, { agent: binary_high_byte("PEN") } ],
      [ :agent_pointer, { agent_pointer: binary_high_byte("125;PSNDF(50.6,") } ],
      [ :type, { type: binary_high_byte("D") } ],
      [ :nature, { nature: binary_high_byte("A") } ],
      [ :originator, { originator: binary_high_byte("42") } ],
      [ :originated_at, { originated_at: binary_high_byte("3261015.1045") } ],
      [ :observed_or_historical, { observed_or_historical: binary_high_byte("o") } ],
      [ :reaction_date, { reaction_date: binary_high_byte("3261015") } ],
      [ :severity, { severity: binary_high_byte("2") } ]
    ]
  end

  def symptom_invalid_utf8_cases
    base = { ien: "10", text: "RASH", date: "3261015" }
    [
      [ :ien, { symptoms: [ base.merge(ien: invalid_utf8("10")) ] } ],
      [ :text, { symptoms: [ base.merge(text: invalid_utf8("RASH")) ] } ],
      [ :date, { symptoms: [ base.merge(date: invalid_utf8("3261015")) ] } ]
    ]
  end

  def symptom_binary_cases
    base = { ien: "10", text: "RASH", date: "3261015" }
    [
      [ :ien, { symptoms: [ base.merge(ien: binary_high_byte("10")) ] } ],
      [ :text, { symptoms: [ base.merge(text: binary_high_byte("RASH")) ] } ],
      [ :date, { symptoms: [ base.merge(date: binary_high_byte("3261015")) ] } ]
    ]
  end

  def comment_invalid_utf8_cases
    [ [ :comment, { comments: [ invalid_utf8("note") ] } ] ]
  end

  def comment_binary_cases
    [ [ :comment, { comments: [ binary_high_byte("note") ] } ] ]
  end

  def invalid_utf8(text)
    "#{text}\xFF".dup.force_encoding(Encoding::UTF_8)
  end

  def binary_high_byte(text)
    "#{text}\xFF".b
  end

  def assert_invalid_value_refusal(field, attrs)
    RpmsRpc.mock!
    result = nil
    begin
      result = RpmsRpc::Allergy.save(DFN, attrs)
    rescue StandardError => e
      flunk "expected invalid_value for #{field}, got #{e.class}: #{e.message}"
    end
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

  def seed_save_reply(value)
    RpmsRpc.mock!
    scalars = RpmsRpc.client.instance_variable_get(:@scalars)
    scalars[RPC] = { "" => [ value ] }
  end
end
