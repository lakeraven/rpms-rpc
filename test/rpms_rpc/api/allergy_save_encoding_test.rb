# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/allergy"

# Issue #485 — Allergy.save and Allergy.no_known_allergies must fail closed on
# text that is not wire-safe before ORWDAL32 SAVE ALLERGY is sent. Only UTF-8
# (valid), US-ASCII, or ASCII-8BIT/BINARY that is pure ASCII may reach the wire;
# UTF-16/32, Shift_JIS, ISO-8859-1, Windows-1252, EUC-JP, and similar tags
# return invalid_value (invalid_dfn for the DFN) with no RPC and must not raise
# (valid_encoding? alone is not enough for UTF-16/32; BINARY with a high byte
# must not rely on regexp Encoding::CompatibilityError).
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

  # Tags that must never be filed on the save path or as a DFN (panel #485 r1).
  NON_WIRE_SAFE_TAGS = %w[
    UTF-16LE UTF-16BE UTF-32LE UTF-32BE Shift_JIS EUC-JP ISO-8859-1 Windows-1252
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

  def test_save_non_ascii_binary_on_every_validated_string_field_returns_invalid_value_without_rpc
    cases = scalar_binary_cases + symptom_binary_cases + comment_binary_cases
    cases.each do |field, attrs|
      assert_invalid_value_refusal(field, SYNTH_ALLERGY.merge(attrs))
    end
  end

  def test_save_non_wire_safe_tag_on_every_validated_string_field_returns_invalid_value_without_rpc
    NON_WIRE_SAFE_TAGS.each do |tag|
      cases = scalar_tagged_cases(tag) + symptom_tagged_cases(tag) + comment_tagged_cases(tag)
      cases.each do |field, attrs|
        assert_invalid_value_refusal(field, SYNTH_ALLERGY.merge(attrs), context: tag)
      end
    end
  end

  # Panel r1: valid_encoding? is true for UTF-16LE "PEN" but regexps still raise.
  def test_save_utf16le_pen_agent_returns_invalid_value_without_raising
    assert_invalid_value_refusal(:agent, SYNTH_ALLERGY.merge(agent: "PEN".encode("UTF-16LE")))
  end

  # Shift_JIS 0x83 0x5E (タ) passes a character caret check but is byte 0x5E ("^") on the wire.
  def test_save_shift_jis_agent_with_high_byte_caret_returns_invalid_value_without_rpc
    agent = ("PEN" + "\x83\x5E").b.force_encoding(Encoding::Shift_JIS)
    assert_invalid_value_refusal(:agent, SYNTH_ALLERGY.merge(agent: agent))
  end

  def test_save_latin1_high_bytes_in_symptom_text_and_comment_return_invalid_value_without_rpc
    latin1 = "note caf\xE9".dup.force_encoding(Encoding::ISO_8859_1)
    assert_invalid_value_refusal(:text, SYNTH_ALLERGY.merge(symptoms: [ symptom_base.merge(text: latin1) ]))
    assert_invalid_value_refusal(:comment, SYNTH_ALLERGY.merge(comments: [ latin1 ]))
  end

  def test_save_refuses_non_wire_safe_dfn_without_rpc
    NON_WIRE_SAFE_TAGS.each do |tag|
      dfn = tagged_ascii("8791", tag)
      assert_invalid_dfn_refusal(dfn) { |patient| RpmsRpc::Allergy.save(patient, SYNTH_ALLERGY) }
    end
  end

  def test_no_known_allergies_refuses_non_wire_safe_dfn_without_rpc
    NON_WIRE_SAFE_TAGS.each do |tag|
      dfn = tagged_ascii("1", tag)
      assert_invalid_dfn_refusal(dfn) { |patient| RpmsRpc::Allergy.no_known_allergies(patient) }
    end
  end

  # Panel r1: no_known_allergies with UTF-16LE DFN must not raise Encoding::CompatibilityError.
  def test_no_known_allergies_utf16le_dfn_returns_invalid_dfn_without_raising
    assert_invalid_dfn_refusal("1".encode("UTF-16LE")) { |patient| RpmsRpc::Allergy.no_known_allergies(patient) }
  end

  def test_save_accepts_pure_ascii_binary_on_every_validated_string_field
    cases = scalar_ascii_binary_cases + symptom_ascii_binary_cases + comment_ascii_binary_cases
    cases.each do |attrs|
      seed_save_reply("0")
      result = RpmsRpc::Allergy.save(DFN, SYNTH_ALLERGY.merge(attrs))
      assert result[:success], result.inspect
      refute_empty RpmsRpc.client.received_calls
    end
  end

  def test_save_accepts_frozen_string_fields
    seed_save_reply("0")
    attrs = SYNTH_ALLERGY.merge(
      agent: SYNTH_ALLERGY[:agent].dup.freeze,
      agent_pointer: SYNTH_ALLERGY[:agent_pointer].dup.freeze,
      type: SYNTH_ALLERGY[:type].dup.freeze,
      nature: SYNTH_ALLERGY[:nature].dup.freeze,
      originator: SYNTH_ALLERGY[:originator].dup.freeze,
      originated_at: SYNTH_ALLERGY[:originated_at].dup.freeze,
      observed_or_historical: SYNTH_ALLERGY[:observed_or_historical].dup.freeze,
      reaction_date: SYNTH_ALLERGY[:reaction_date].dup.freeze,
      severity: SYNTH_ALLERGY[:severity].dup.freeze,
      symptoms: [
        {
          ien: "10".dup.freeze,
          text: "RASH".dup.freeze,
          date: "3261015".dup.freeze
        }
      ],
      comments: [ "synthetic comment".dup.freeze ]
    )
    result = RpmsRpc::Allergy.save(DFN, attrs)
    assert result[:success], result.inspect
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

  def symptom_base
    { ien: "10", text: "RASH", date: "3261015" }
  end

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

  def scalar_tagged_cases(tag)
    [
      [ :agent, { agent: tagged_ascii("PENICILLIN", tag) } ],
      [ :agent_pointer, { agent_pointer: tagged_ascii("125;PSNDF(50.6,", tag) } ],
      [ :type, { type: tagged_ascii("D", tag) } ],
      [ :nature, { nature: tagged_ascii("A", tag) } ],
      [ :originator, { originator: tagged_ascii("42", tag) } ],
      [ :originated_at, { originated_at: tagged_ascii("3261015.1045", tag) } ],
      [ :observed_or_historical, { observed_or_historical: tagged_ascii("o", tag) } ],
      [ :reaction_date, { reaction_date: tagged_ascii("3261015", tag) } ],
      [ :severity, { severity: tagged_ascii("2", tag) } ]
    ]
  end

  def symptom_invalid_utf8_cases
    base = symptom_base
    [
      [ :ien, { symptoms: [ base.merge(ien: invalid_utf8("10")) ] } ],
      [ :text, { symptoms: [ base.merge(text: invalid_utf8("RASH")) ] } ],
      [ :date, { symptoms: [ base.merge(date: invalid_utf8("3261015")) ] } ]
    ]
  end

  def symptom_binary_cases
    base = symptom_base
    [
      [ :ien, { symptoms: [ base.merge(ien: binary_high_byte("10")) ] } ],
      [ :text, { symptoms: [ base.merge(text: binary_high_byte("RASH")) ] } ],
      [ :date, { symptoms: [ base.merge(date: binary_high_byte("3261015")) ] } ]
    ]
  end

  def symptom_tagged_cases(tag)
    base = symptom_base
    [
      [ :ien, { symptoms: [ base.merge(ien: tagged_ascii("10", tag)) ] } ],
      [ :text, { symptoms: [ base.merge(text: tagged_ascii("RASH", tag)) ] } ],
      [ :date, { symptoms: [ base.merge(date: tagged_ascii("3261015", tag)) ] } ]
    ]
  end

  def comment_invalid_utf8_cases
    [ [ :comment, { comments: [ invalid_utf8("note") ] } ] ]
  end

  def comment_binary_cases
    [ [ :comment, { comments: [ binary_high_byte("note") ] } ] ]
  end

  def comment_tagged_cases(tag)
    [ [ :comment, { comments: [ tagged_ascii("note", tag) ] } ] ]
  end

  def scalar_ascii_binary_cases
    [
      { agent: ascii_binary("PENICILLIN") },
      { agent_pointer: ascii_binary("125;PSNDF(50.6,") },
      { type: ascii_binary("D") },
      { nature: ascii_binary("A") },
      { originator: ascii_binary("42") },
      { originated_at: ascii_binary("3261015.1045") },
      { observed_or_historical: ascii_binary("o") },
      { reaction_date: ascii_binary("3261015") },
      { severity: ascii_binary("2") }
    ]
  end

  def symptom_ascii_binary_cases
    base = symptom_base
    [
      { symptoms: [ base.merge(ien: ascii_binary("10"), text: ascii_binary("RASH"), date: ascii_binary("3261015")) ] }
    ]
  end

  def comment_ascii_binary_cases
    [ { comments: [ ascii_binary("note") ] } ]
  end

  def invalid_utf8(text)
    "#{text}\xFF".dup.force_encoding(Encoding::UTF_8)
  end

  def binary_high_byte(text)
    "#{text}\xFF".b
  end

  def ascii_binary(text)
    text.b
  end

  MULTIBYTE_WIRE_UNSAFE_TAGS = %w[UTF-16LE UTF-16BE UTF-32LE UTF-32BE].freeze

  def tagged_ascii(text, tag_name)
    encoding = Encoding.find(tag_name)
    if MULTIBYTE_WIRE_UNSAFE_TAGS.include?(tag_name)
      text.encode(encoding)
    else
      text.b.force_encoding(encoding)
    end
  end

  def assert_invalid_value_refusal(field, attrs, context: nil)
    RpmsRpc.mock!
    result = nil
    begin
      result = RpmsRpc::Allergy.save(DFN, attrs)
    rescue StandardError => e
      label = [ field, context ].compact.join(" ")
      flunk "expected invalid_value for #{label}, got #{e.class}: #{e.message}"
    end
    expected = { success: false, error: :invalid_value, message: "invalid #{field}" }
    unless result == expected
      rpc_sent = !RpmsRpc.client.received_calls.empty?
      label = [ field, context ].compact.join(" ")
      flunk "expected #{expected.inspect} for #{label}, got #{result.inspect} (RPC sent: #{rpc_sent})"
    end
    label = [ field, context ].compact.join(" ")
    assert_empty RpmsRpc.client.received_calls, "invalid #{label}"
  end

  def assert_invalid_dfn_refusal(dfn)
    RpmsRpc.mock!
    result = nil
    begin
      result = yield(dfn)
    rescue StandardError => e
      flunk "expected invalid_dfn for #{dfn.encoding.name}, got #{e.class}: #{e.message}"
    end
    expected = { success: false, error: :invalid_dfn, message: "a positive DFN is required" }
    unless result == expected
      rpc_sent = !RpmsRpc.client.received_calls.empty?
      flunk "expected #{expected.inspect} for #{dfn.encoding.name}, got #{result.inspect} (RPC sent: #{rpc_sent})"
    end
    assert_empty RpmsRpc.client.received_calls, "invalid dfn #{dfn.encoding.name}"
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
