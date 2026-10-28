# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"

# rpms-rpc#477 round 3: a Reply::Text altered by control characters holds no
# replacement character, so the line that changed cannot be located. It must
# keep its flag anyway: the whole blob is treated as altered, never as clean.
# Every byte string is SYNTHETIC.
class RpmsRpc::AlteredTextControlsTest < Minitest::Test
  def assess(reply)
    client = Object.new
    client.define_singleton_method(:call_rpc) { |*| reply }
    RpmsRpc.configure { |c| c.client = client }
    RpmsRpc::Allergy.assessment("1")
  end

  def altered_marker_text = RpmsRpc::Reply.text("^No\x1fKnown Allergies".b, controls: true)

  def test_the_setup_is_altered_and_holds_no_replacement_character
    text = altered_marker_text

    assert RpmsRpc::Reply.altered?(text)
    refute_includes text, RpmsRpc::Reply::REPLACEMENT
  end

  def test_a_controls_altered_text_marker_is_never_nka
    result = assess(altered_marker_text)

    assert_equal false, result[:nka]
    assert_equal false, result[:assessed]
    assert_equal true, result[:conflict]
  end

  def test_a_plain_array_holding_a_controls_altered_text_is_never_nka
    result = assess([ altered_marker_text ])

    assert_equal false, result[:nka]
    assert_equal true, result[:conflict]
  end

  def test_a_controls_altered_text_flags_every_row_it_carries
    text = RpmsRpc::Reply.text("1^LATEX\u20282^PEN\x01\u20283^NUTS".b, controls: true)
    result = assess(text)

    assert_equal [ true, true, true ], result[:allergies].map { |row| row[:altered] }
  end

  def test_call_rpc_lines_keeps_the_flag_of_a_controls_altered_text
    client = Class.new(RpmsRpc::Client) do
      def initialize; end

      def call_rpc(*) = RpmsRpc::Reply.text("^No\x1fKnown Allergies".b, controls: true)
    end.new

    lines = client.call_rpc_lines("X")

    assert_equal true, lines.altered?
    assert_equal [ 0 ], lines.altered_lines
  end

  def test_lines_with_altered_flags_every_line_of_a_controls_altered_text
    lines, altered = RpmsRpc::Reply.lines_with_altered(RpmsRpc::Reply.text("1^A\x1f2^B".b, controls: true))

    assert_equal [ "1^A 2^B" ], lines
    assert_equal [ 0 ], altered
  end

  def test_an_invalid_byte_text_still_flags_only_the_lines_holding_the_replacement
    text = RpmsRpc::Reply.text("1^LATEX\n2^PEN\xFF^S".b)
    _lines, altered = RpmsRpc::Reply.lines_with_altered(text)

    assert_equal [ 1 ], altered
  end

  def test_a_clean_text_marker_is_still_nka_as_text_and_in_an_array
    clean = RpmsRpc::Reply.text("^No Known Allergies", controls: true)

    assert_equal({ assessed: true, nka: true, allergies: [] }, assess(clean))
    assert_equal({ assessed: true, nka: true, allergies: [] }, assess([ clean ]))
  end

  def test_a_clean_text_of_rows_is_unchanged_and_unflagged
    result = assess(RpmsRpc::Reply.text("1^LATEX\n2^PEN^S"))

    assert_equal true, result[:assessed]
    assert_equal [ false, false ], result[:allergies].map { |row| row[:altered] }
  end
end
