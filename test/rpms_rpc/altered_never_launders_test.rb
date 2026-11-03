# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"

# rpms-rpc#463 x #483 panel findings on #477: an altered line is never read as
# verified. An altered marker is never NKA on the CIA path (control
# characters), a Reply is only built through its constructors, and a Reply::Text
# keeps its flag through every wrapper. Every byte string is SYNTHETIC.
class RpmsRpc::AlteredNeverLaundersTest < Minitest::Test
  def teardown
    RpmsRpc.reset!
  end

  def assess(reply)
    client = Object.new
    client.define_singleton_method(:call_rpc) { |*| reply }
    RpmsRpc.configure { |c| c.client = client }
    RpmsRpc::Allergy.assessment("1")
  end

  def cia(line) = RpmsRpc::Reply.from_wire([ line.b ], controls: true)

  [ "\x1f", "\x01", "\x7f" ].each do |control|
    define_method("test_a_marker_altered_by_a_control_character_#{control.ord}_is_never_nka") do
      reply = cia("^No#{control}Known Allergies")
      result = assess(reply)

      assert reply.altered?
      assert_equal false, result[:nka]
      assert_equal false, result[:assessed]
      assert_equal true, result[:conflict]
    end
  end

  def test_a_marker_altered_by_a_control_character_beside_a_row_keeps_the_row
    result = assess(RpmsRpc::Reply.from_wire([ "^No\x1fKnown Allergies".b, "1^LATEX" ], controls: true))

    assert_equal false, result[:nka]
    assert_equal true, result[:conflict]
    assert_includes result[:allergies].map { |row| row[:allergen] }, "LATEX"
  end

  def test_the_clean_marker_is_still_nka_through_the_cia_path_and_as_a_plain_array
    assert_equal({ assessed: true, nka: true, allergies: [] }, assess(cia("^No Known Allergies")))
    assert_equal({ assessed: true, nka: true, allergies: [] }, assess([ "^No Known Allergies" ]))
  end

  def test_a_reply_cannot_be_built_with_the_array_constructor
    assert_raises(NoMethodError) { RpmsRpc::Reply.public_send(:[], "1^LATEX") }
  end

  def test_every_reply_answers_altered_without_raising
    reply = RpmsRpc::Reply.from_wire([ "1^LATEX" ])

    assert_equal false, reply.altered?
    assert_equal false, RpmsRpc::Reply.altered?(reply)
  end

  def test_call_rpc_lines_keeps_the_flag_of_a_text_reply
    client = Class.new(RpmsRpc::Client) do
      def initialize; end

      def call_rpc(*) = RpmsRpc::Reply.text("1^PEN\xFF^S".b)
    end.new

    lines = client.call_rpc_lines("X")

    assert_equal [ "1^PEN�^S" ], lines
    assert_equal true, lines.altered?
  end

  def test_from_wire_keeps_the_flag_of_a_text_element
    text = RpmsRpc::Reply.text("1^PEN\xFF^S".b)
    reply = RpmsRpc::Reply.from_wire([ text ])

    assert_equal true, reply.altered?
    assert_equal [ 0 ], reply.altered_lines
  end

  def test_a_clean_text_element_does_not_flag_the_reply
    reply = RpmsRpc::Reply.from_wire([ RpmsRpc::Reply.text("1^LATEX") ])

    assert_equal false, reply.altered?
  end
end
