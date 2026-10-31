# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"

# rpms-rpc#463 x #483: the altered flag composes with the allergy classifier.
# Altered text is never a conflict by itself, never NKA, and the flag follows
# its own line in a conflicting reply. Every byte string is SYNTHETIC.
class RpmsRpc::AllergyAlteredConflictTest < Minitest::Test
  def teardown
    RpmsRpc.reset!
  end

  def assess(reply)
    client = Object.new
    client.define_singleton_method(:call_rpc) { |*| reply }
    RpmsRpc.configure { |c| c.client = client }
    RpmsRpc::Allergy.assessment("1")
  end

  def test_an_altered_clean_row_is_assessed_not_a_conflict
    result = assess(RpmsRpc::Reply.from_wire([ "1^LATEX", "2^PENI\xFFCILLIN^S".b ]))

    assert_equal true, result[:assessed]
    refute result.key?(:conflict)
    assert_equal [ false, true ], result[:allergies].map { |row| row[:altered] }
  end

  def test_the_flag_follows_its_own_row_beside_a_marker
    result = assess(RpmsRpc::Reply.from_wire([ "^No Known Allergies", "2^PEN\xFF^S".b ]))

    assert_equal({ assessed: false, nka: false, conflict: true }, result.slice(:assessed, :nka, :conflict))
    assert_equal [ true ], result[:allergies].map { |row| row[:altered] }
  end

  def test_an_altered_unrecognised_line_is_surfaced_flagged_and_its_clean_neighbour_is_not
    result = assess(RpmsRpc::Reply.from_wire([ "bad\xFF line".b, "1^LATEX" ]))

    assert_equal true, result[:conflict]
    surfaced, row = result[:allergies]
    assert_equal true, surfaced[:unrecognised]
    assert_equal true, surfaced[:altered]
    assert_equal false, row[:altered]
  end

  def test_an_unaltered_unrecognised_line_carries_no_altered_key
    result = assess(RpmsRpc::Reply.from_wire([ "garbage", "1^LATEX" ]))

    refute result[:allergies].first.key?(:altered)
  end

  def test_a_utf8_tagged_invalid_line_in_a_plain_array_is_flagged_altered
    result = assess([ "1^PEN\xFFICILLIN" ])

    assert_equal true, result[:assessed]
    refute result.key?(:conflict)
    assert_equal [ true ], result[:allergies].map { |row| row[:altered] }
  end

  def test_an_altered_marker_is_never_nka
    result = assess(RpmsRpc::Reply.from_wire([ "^No Known Allergies\xFF".b ]))

    assert_equal false, result[:nka]
  end

  def test_a_text_blob_flags_only_the_lines_holding_the_replacement
    result = assess(RpmsRpc::Reply.text("1^LATEX\n2^PEN\xFF^S".b))

    assert_equal [ false, true ], result[:allergies].map { |row| row[:altered] }
  end
end
