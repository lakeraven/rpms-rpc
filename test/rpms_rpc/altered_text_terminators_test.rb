# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"

# rpms-rpc#477 round 4: controls: true on a blob must not fold its line
# terminators into spaces, or two lines become one assessed row and a marker or
# a second allergy hides inside a field. Every byte string is SYNTHETIC.
class RpmsRpc::AlteredTextTerminatorsTest < Minitest::Test
  def assess(reply)
    client = Object.new
    client.define_singleton_method(:call_rpc) { |*| reply }
    RpmsRpc.configure { |c| c.client = client }
    RpmsRpc::Allergy.assessment("1")
  end

  def text(blob) = RpmsRpc::Reply.text(blob, controls: true)

  def test_a_controls_text_keeps_its_line_terminators
    assert_equal "1^A\n^No Known Allergies", text("1^A\n^No Known Allergies")
    assert_equal "1^A\r\n2^B", text("1^A\r\n2^B")
  end

  def test_a_marker_beside_a_row_is_a_conflict_with_controls_too
    result = assess(text("1^PENICILLIN\n^No Known Allergies"))

    assert_equal false, result[:assessed]
    assert_equal false, result[:nka]
    assert_equal true, result[:conflict]
  end

  def test_a_second_allergy_is_never_folded_into_the_first_row
    result = assess(text("1^PENICILLIN\r\n2^LATEX"))

    assert_equal %w[PENICILLIN LATEX], result[:allergies].map { |row| row[:allergen] }
  end

  def test_a_control_character_in_one_line_still_alters_every_line_and_keeps_both_rows
    result = assess(text("1^PENI\x1fCILLIN\n2^LATEX"))

    assert_equal 2, result[:allergies].size
    assert_equal [ true, true ], result[:allergies].map { |row| row[:altered] }
  end

  def test_a_clean_blob_is_unchanged_by_controls
    blob = "1^PENICILLIN\r\n2^LATEX^SEVERE\n"
    clean = assess(text(blob))
    plain = assess(blob)

    refute RpmsRpc::Reply.altered?(text(blob))
    assert_equal plain, clean
  end

  # The CIA line path (a row and a marker joined by a control character) is a
  # documented limit shared with main, pinned so the docs stay true.
  def test_a_cia_line_joined_by_a_control_character_is_documented_as_an_altered_row
    reply = RpmsRpc::Reply.from_wire([ "1^PENICILLIN\x1f^No Known Allergies".b ], controls: true)
    result = assess(reply)

    assert_equal true, result[:allergies].first[:altered]
    assert_equal "PENICILLIN", result[:allergies].first[:allergen].strip
  end
end
