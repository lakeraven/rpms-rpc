# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/xwb_client"
require "rpms_rpc/api/progress_note"

# Issue #479 (SPEC): long TIU note lines are wrapped before TIU SET DOCUMENT TEXT.
# These tests pin the wrap_width API, piece boundaries, readback, UTF-8 safety,
# blank-line preservation, validation, and XWB L-PACK limits. They fail until
# ProgressNote#update_text implements wrapping.
class ProgressNoteWrapTest < Minitest::Test
  NOTE_IEN = "5001"

  def teardown
    RpmsRpc.reset!
  end

  def params_sent_to(rpc)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == rpc }
    refute_nil call, "#{rpc} was not called"
    call[:params]
  end

  def tiux_from_params(params)
    refute_nil params[1], "TIUX list param missing"
    params[1]
  end

  def text_values_in_order(tiux)
    tiux.select { |k, _| k.is_a?(Array) && k.first == "TEXT" }
        .sort_by { |k, _| k[1] }
        .map(&:last)
  end

  def assert_valid_utf8_strings(values)
    values.each do |v|
      assert v.valid_encoding?, "expected valid UTF-8, got #{v.encoding} #{v.inspect}"
    end
  end

  def assert_pieces_at_most(values, wrap_width)
    values.each { |v| assert_operator v.bytesize, :<=, wrap_width, v.inspect }
  end

  def assert_update_succeeds(note_ien, text, wrap_width: nil)
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_set_document_text, note_ien, "#{note_ien}^1^1") }
    result = if wrap_width.nil?
               RpmsRpc::ProgressNote.update_text(note_ien, text)
    else
               RpmsRpc::ProgressNote.update_text(note_ien, text, wrap_width: wrap_width)
    end
    assert_equal({ success: true, raw: "#{note_ien}^1^1" }, result)
    result
  end

  def sent_text_lines(note_ien, text, wrap_width:)
    assert_update_succeeds(note_ien, text, wrap_width: wrap_width)
    text_values_in_order(tiux_from_params(params_sent_to("TIU SET DOCUMENT TEXT")))
  end

  def assert_tiux_sent_pieces(text, wrap_width:, expected_pieces:, note_ien: NOTE_IEN)
    sent = sent_text_lines(note_ien, text, wrap_width: wrap_width)
    assert_equal expected_pieces, sent
  end

  # Original line is recovered by concatenating sent pieces in order; after each
  # piece except the last, optionally skip exactly one space or tab in the original
  # (soft breaks drop one whitespace character).
  def assert_logical_line_rejoins_from_sent_pieces(original_line, sent_pieces)
    pos = 0
    sent_pieces.each_with_index do |piece, idx|
      expected_slice = original_line.byteslice(pos, piece.bytesize)
      assert_equal piece, expected_slice,
                   "piece #{idx} #{piece.inspect} at byte #{pos}, expected #{expected_slice.inspect}"
      pos += piece.bytesize
      next if idx == sent_pieces.length - 1

      if pos < original_line.bytesize && original_line[pos] =~ /[ \t]/
        pos += 1
      end
    end
    assert_equal original_line.bytesize, pos,
                 "sent pieces did not consume full line #{original_line.inspect}"
  end

  def assert_sent_line_satisfies_readback(original_line, wrap_width:, note_ien: NOTE_IEN)
    sent = sent_text_lines(note_ien, original_line, wrap_width: wrap_width)
    assert_pieces_at_most(sent, wrap_width)
    assert_valid_utf8_strings(sent)
    assert_logical_line_rejoins_from_sent_pieces(original_line, sent)
    sent
  end

  def lpack_payload_values(binary)
    values = []
    i = 0
    b = binary.b
    while i <= b.bytesize - 3
      head = b.byteslice(i, 3)
      if head.match?(/\A\d{3}\z/)
        len = head.to_i
        if len <= 999 && i + 3 + len <= b.bytesize
          values << b.byteslice(i + 3, len)
          i += 3 + len
          next
        end
      end
      i += 1
    end
    values
  end

  def assert_xwb_message_framed_without_lpack_refusal(params)
    client = RpmsRpc::XwbClient.new
    encoded = params.map { |p| client.encode_param(p) }
    msg = client.build_rpc_message("TIU SET DOCUMENT TEXT", encoded)
    values = lpack_payload_values(msg)
    refute_empty values, "expected L-PACK values in the XWB message"
    values.each do |v|
      assert_operator v.bytesize, :<=, 999, "L-PACK value length #{v.bytesize} exceeds 999"
    end
    msg
  end

  def assert_wire_framed_without_lpack_refusal(wire_chunks)
    wire = wire_chunks.reduce(+"".b) { |acc, chunk| acc << chunk }
    values = lpack_payload_values(wire)
    refute_empty values, "expected L-PACK values on the wire"
    values.each do |v|
      assert_operator v.bytesize, :<=, 999, "L-PACK value length #{v.bytesize} exceeds 999"
    end
  end

  # -- acceptance -------------------------------------------------------------

  def test_two_thousand_byte_single_line_wraps_to_eighty_byte_tiux_lines_and_readback
    unit = "tok "
    line = (unit * 600).byteslice(0, 2000)
    assert_equal 2000, line.bytesize
    refute_includes line, "\n"

    assert_update_succeeds(NOTE_IEN, line)
    tiux = tiux_from_params(params_sent_to("TIU SET DOCUMENT TEXT"))
    values = text_values_in_order(tiux)
    refute_empty values
    assert_pieces_at_most(values, RpmsRpc::ProgressNote::WRAP_WIDTH)
    joined = values.join(" ")
    assert_equal line, joined
  end

  def test_wrap_width_constant_is_eighty_bytes
    assert_equal 80, RpmsRpc::ProgressNote::WRAP_WIDTH
  end

  # -- exact pieces at small width (hand-computed from brief479 wrap rule) --

  def test_wrap_width_ten_splits_words_on_last_space_in_window
    assert_tiux_sent_pieces(
      "one two three four",
      wrap_width: 10,
      expected_pieces: [ "one two", "three four" ]
    )
  end

  def test_wrap_width_ten_breaks_on_last_space_before_width_with_multi_space_run
    assert_tiux_sent_pieces(
      "alpha  beta",
      wrap_width: 10,
      expected_pieces: [ "alpha ", "beta" ]
    )
  end

  def test_wrap_width_ten_breaks_on_tab_before_width
    assert_tiux_sent_pieces(
      "left\trights side",
      wrap_width: 10,
      expected_pieces: [ "left", "rights", "side" ]
    )
  end

  def test_wrap_width_ten_breaks_on_tab_after_space_when_tab_is_last_eligible_whitespace
    assert_tiux_sent_pieces(
      "ab cd\tefghij",
      wrap_width: 10,
      expected_pieces: [ "ab cd", "efghij" ]
    )
  end

  def test_wrap_width_ten_hard_breaks_a_long_word_with_no_whitespace
    assert_tiux_sent_pieces(
      "abcdefghijk",
      wrap_width: 10,
      expected_pieces: [ "abcdefghij", "k" ]
    )
  end

  def test_wrap_width_ten_mixed_soft_and_hard_breaks
    assert_tiux_sent_pieces(
      "ab cd efghijklmn",
      wrap_width: 10,
      expected_pieces: [ "ab cd", "efghijklmn" ]
    )
  end

  def test_wrap_width_ten_keeps_indent_on_first_piece_only
    assert_tiux_sent_pieces(
      "  one two three",
      wrap_width: 10,
      expected_pieces: [ "  one two", "three" ]
    )
  end

  def test_wrap_width_ten_indented_line_hard_breaks_after_indent_not_at_offset_zero
    line = (" " * 5) + ("x" * 12)
    assert_tiux_sent_pieces(
      line,
      wrap_width: 10,
      expected_pieces: [ (" " * 5) + ("x" * 5), "x" * 7 ]
    )
  end

  def test_wrap_width_ten_leaves_line_of_exactly_ten_bytes_unchanged
    line = "1234567890"
    assert_equal 10, line.bytesize
    assert_tiux_sent_pieces(line, wrap_width: 10, expected_pieces: [ line ])
  end

  def test_wrap_width_ten_splits_line_of_eleven_bytes
    assert_tiux_sent_pieces(
      "12345678901",
      wrap_width: 10,
      expected_pieces: [ "1234567890", "1" ]
    )
  end

  # -- readback property (gem output only; no duplicate wrap implementation) --

  def test_readback_rejoins_soft_and_hard_breaks_for_several_inputs
    samples = [
      [ "one two three", 10 ],
      [ "alpha  beta gamma", 10 ],
      [ "left\tright end", 10 ],
      [ "abcdefghijklmnop", 10 ],
      [ "  indented wrap", 10 ],
      [ (" " * 4) + ("z" * 15), 10 ],
      [ "é" * 6, 10 ],
      [ "€" * 5, 10 ],
      [ "😀" * 4, 10 ]
    ]
    samples.each do |line, width|
      assert_sent_line_satisfies_readback(line, wrap_width: width)
    end
  end

  # -- multibyte (literal piece boundaries at small width) --------------------

  def test_multibyte_two_byte_e_acute_wrapped_at_width_ten
    assert_tiux_sent_pieces(
      "é" * 6,
      wrap_width: 10,
      expected_pieces: [ "é" * 5, "é" ]
    )
  end

  def test_multibyte_three_byte_euro_wrapped_at_width_ten
    assert_tiux_sent_pieces(
      "€" * 5,
      wrap_width: 10,
      expected_pieces: [ "€" * 3, "€" * 2 ]
    )
  end

  def test_multibyte_four_byte_emoji_wrapped_at_width_ten
    assert_tiux_sent_pieces(
      "😀" * 4,
      wrap_width: 10,
      expected_pieces: [ "😀" * 2, "😀" * 2 ]
    )
  end

  def test_multibyte_lines_sent_pieces_are_valid_utf8_and_rejoin_at_various_widths
    lines = [
      "é" * 8,
      "€" * 6,
      "😀" * 5
    ]
    lines.each do |line|
      [ 4, 7, 10 ].each do |width|
        assert_sent_line_satisfies_readback(line, wrap_width: width)
      end
    end
  end

  # -- blank and short lines in multi-line notes ------------------------------

  def test_blank_lines_and_short_lines_stay_unwrapped_in_a_multi_line_note
    text = "S: brief\n\nO: also short\n"
    assert_update_succeeds(NOTE_IEN, text)
    assert_equal [ NOTE_IEN, {
      "HDR" => "1^1",
      [ "TEXT", 1, 0 ] => "S: brief",
      [ "TEXT", 2, 0 ] => "",
      [ "TEXT", 3, 0 ] => "O: also short"
    } ], params_sent_to("TIU SET DOCUMENT TEXT")
  end

  def test_existing_two_line_update_shape_unchanged_at_default_width
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_set_document_text, NOTE_IEN, "#{NOTE_IEN}^1^1") }
    RpmsRpc::ProgressNote.update_text(NOTE_IEN, "S: cough\nO: afebrile")
    assert_equal [ NOTE_IEN, { "HDR" => "1^1", [ "TEXT", 1, 0 ] => "S: cough", [ "TEXT", 2, 0 ] => "O: afebrile" } ],
                 params_sent_to("TIU SET DOCUMENT TEXT")
  end

  # -- XWB framing --------------------------------------------------------------

  def test_five_thousand_byte_line_sends_no_tiux_value_over_999_bytes_at_default_width
    line = ("word " * 1200).byteslice(0, 5000)
    assert_operator line.bytesize, :>, 999

    assert_update_succeeds(NOTE_IEN, line)
    params = params_sent_to("TIU SET DOCUMENT TEXT")
    tiux = tiux_from_params(params)
    text_values_in_order(tiux).each do |v|
      assert_operator v.bytesize, :<=, 999
      assert_operator v.bytesize, :<=, RpmsRpc::ProgressNote::WRAP_WIDTH
    end
    assert_xwb_message_framed_without_lpack_refusal(params)
  end

  def test_five_thousand_byte_line_at_wrap_width_999_fits_lpack_limit
    line = "y" * 5000
    assert_update_succeeds(NOTE_IEN, line, wrap_width: 999)
    params = params_sent_to("TIU SET DOCUMENT TEXT")
    text_values_in_order(tiux_from_params(params)).each { |v| assert_operator v.bytesize, :<=, 999 }
    assert_xwb_message_framed_without_lpack_refusal(params)
  end

  def test_single_line_that_used_to_hit_frame_too_long_now_succeeds_on_xwb
    line = "n" * 5000
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_set_document_text, NOTE_IEN, "#{NOTE_IEN}^1^1") }
    client = RpmsRpc::XwbClient.new
    socket_writes = []
    socket = Object.new
    socket.define_singleton_method(:write) { |s| socket_writes << s.b; s.bytesize }
    socket.define_singleton_method(:recv) { |_n| "" }
    socket.define_singleton_method(:flush) { }
    socket.define_singleton_method(:close) { }
    socket.define_singleton_method(:closed?) { false }
    socket.define_singleton_method(:setsockopt) { |*| }
    client.instance_variable_set(:@socket, socket)
    client.instance_variable_set(:@connected, true)
    client.define_singleton_method(:read_response) { "#{NOTE_IEN}^1^1" }
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = RpmsRpc::ProgressNote.update_text(NOTE_IEN, line)
    assert_equal true, result[:success], result.inspect
    refute_empty socket_writes, "wrapped update must reach the wire"
    assert_wire_framed_without_lpack_refusal(socket_writes)
  end

  # -- wrap_width validation ----------------------------------------------------

  def test_invalid_wrap_width_raises_argument_error_and_sends_no_rpc
    bad_values = [ nil, 3, 1000, "80", 80.0 ]
    bad_values.each do |bad|
      RpmsRpc.mock!
      error = assert_raises(ArgumentError) do
        RpmsRpc::ProgressNote.update_text(NOTE_IEN, "x", wrap_width: bad)
      end
      assert_match(/wrap_width/i, error.message)
      assert_empty RpmsRpc.client.received_calls, "wrap_width #{bad.inspect} must not RPC"
    end
  end

  def test_wrap_width_four_is_allowed
    assert_tiux_sent_pieces(
      "abcd efgh",
      wrap_width: 4,
      expected_pieces: [ "abcd", "efgh" ]
    )
  end

  # -- invalid UTF-8 ----------------------------------------------------------

  def test_invalid_utf8_returns_failure_shape_and_sends_no_rpc
    invalid = "\xFF".b
    RpmsRpc.mock!
    result = RpmsRpc::ProgressNote.update_text(NOTE_IEN, invalid)
    assert_equal false, result[:success]
    assert_nil result[:raw]
    assert_match(/UTF-8/i, result[:error].to_s)
    assert_empty RpmsRpc.client.received_calls
  end

  def test_ascii8bit_invalid_utf8_returns_failure_shape_and_sends_no_rpc
    invalid = String.new("\xC0\x80", encoding: Encoding::ASCII_8BIT)
    RpmsRpc.mock!
    result = RpmsRpc::ProgressNote.update_text(NOTE_IEN, invalid)
    assert_equal false, result[:success]
    assert_nil result[:raw]
    assert_match(/UTF-8/i, result[:error].to_s)
    assert_empty RpmsRpc.client.received_calls
  end
end
