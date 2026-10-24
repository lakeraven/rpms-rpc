# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/xwb_client"
require "rpms_rpc/bmx_client"
require "rpms_rpc/cia_client"
require "rpms_rpc/mock_client"
require "rpms_rpc/mappings"

# rpms-rpc#463 — a reply reaches the host as valid UTF-8, and a reply whose
# bytes had to be altered says so.
#
# CHARSET: assumed UTF-8, UNPROVEN. Latin-1 is observed in stored data
# (conformance/build_surface.rb:292-297; patient.rb:314 notes non-UTF-8 name
# bytes), so real Latin-1 text WILL read as altered. That is the accepted,
# fail-closed behaviour until a live read settles the wire charset.
#
# Every byte string below is SYNTHETIC: clearly invented text, never a
# recorded reply.
class RpmsRpc::ReplyEncodingTest < Minitest::Test
  EOT = RpmsRpc::Client::EOT
  EOD = RpmsRpc::Client::EOD

  VALID_UTF8 = "caf\xC3\xA9 SYNTHETIC".b      # "café SYNTHETIC" as UTF-8 bytes
  INVALID    = "caf\xE9 SYNTHETIC".b           # a lone Latin-1 byte: not valid UTF-8
  ASCII      = "PLAIN SYNTHETIC".b

  class FakeSocket
    def initialize(reads) = (@reads = reads.dup)
    def write(str) = str.bytesize
    def recv(_n) = @reads.empty? ? "" : @reads.shift.b
    def flush; end
    def close = @closed = true
    def closed? = !!@closed
    def setsockopt(*); end
  end

  def wired(client, reads)
    client.instance_variable_set(:@socket, FakeSocket.new(reads))
    client.instance_variable_set(:@connected, true)
    client.instance_variable_set(:@timeout, 1)
    client
  end

  def xwb(body) = wired(RpmsRpc::XwbClient.new, [ "\x00\x00".b + body + EOT ])
  def bmx(body) = wired(RpmsRpc::BmxClient.new, [ "\x00\x00".b + body + EOT ])
  def cia(body) = wired(RpmsRpc::CiaClient.new, [ "1\x00".b + body + EOD ]).tap { |c| c.instance_variable_set(:@seq, 0) }

  TRANSPORTS = { xwb: :xwb, bmx: :bmx, cia: :cia }.freeze

  TRANSPORTS.each_key do |name|
    define_method("test_#{name}_valid_non_ascii_reply_is_valid_utf8_and_joins_with_a_utf8_literal") do
      reply = send(name, VALID_UTF8).call_rpc("SYNTHETIC RPC")
      line = reply.first
      assert_equal Encoding::UTF_8, line.encoding
      assert line.valid_encoding?
      assert_equal "café SYNTHETIC", line
      assert_equal "x — café SYNTHETIC", [ "x", line ].join(" — ") # no Encoding::CompatibilityError
      refute reply.altered?, "valid UTF-8 was not altered"
    end

    define_method("test_#{name}_invalid_byte_becomes_replacement_char_and_the_reply_says_altered") do
      reply = send(name, INVALID).call_rpc("SYNTHETIC RPC")
      line = reply.first
      assert_equal Encoding::UTF_8, line.encoding
      assert line.valid_encoding?
      assert_equal "caf� SYNTHETIC", line
      assert reply.altered?, "an invalid byte was replaced, so the reply must say so"
      assert_equal [ 0 ], reply.altered_lines
    end

    define_method("test_#{name}_pure_ascii_reply_is_utf8_and_not_altered") do
      reply = send(name, ASCII).call_rpc("SYNTHETIC RPC")
      assert_equal Encoding::UTF_8, reply.first.encoding
      assert_equal "PLAIN SYNTHETIC", reply.first
      refute reply.altered?
      assert_empty reply.altered_lines
    end
  end

  # CIA's printable() turned every byte outside 0x20-0x7e into a space with no
  # signal. Control characters still become a space (existing behaviour), but
  # the reply now says it altered them; valid non-ASCII text is no longer
  # destroyed.
  def test_cia_control_character_still_becomes_a_space_and_is_flagged
    reply = cia("ab\x1fcd".b).call_rpc("SYNTHETIC RPC")
    assert_equal [ "ab cd" ], reply
    assert reply.altered?
  end

  def test_altered_lines_names_only_the_lines_that_changed
    reply = xwb("ok line\r\ncaf\xE9 line\r\nfine line".b).call_rpc("SYNTHETIC RPC")
    assert_equal [ "ok line", "caf� line", "fine line" ], reply
    assert_equal [ 1 ], reply.altered_lines
  end

  def test_reply_is_still_an_array_of_strings
    reply = xwb(ASCII).call_rpc("SYNTHETIC RPC")
    assert_kind_of Array, reply
    assert_equal [ "PLAIN SYNTHETIC" ], reply
  end

  def test_altered_helper_reads_false_for_a_plain_array
    refute RpmsRpc::Reply.altered?([ "plain" ])
    refute RpmsRpc::Reply.altered?(nil)
  end

  # MockClient replies follow the same rule, so host tests see production
  # encoding.
  def test_mock_client_reply_is_valid_utf8_and_flags_alteration
    mock = RpmsRpc::MockClient.new
    rpc = RpmsRpc::DataMapper[:site_info].rpc_name
    mock.seed_raw_lines(:site_info, "", [ VALID_UTF8.dup, INVALID.dup, ASCII.dup ])
    reply = mock.call_rpc(rpc, "")
    assert(reply.all? { |l| l.encoding == Encoding::UTF_8 && l.valid_encoding? })
    assert_equal [ "café SYNTHETIC", "caf� SYNTHETIC", "PLAIN SYNTHETIC" ], reply
    assert reply.altered?
    assert_equal [ 1 ], reply.altered_lines
  end

  # Copilot round (#477): a reply seeded as a bare String is sanitised once,
  # where the invalid bytes are replaced, and that fact must reach the line
  # reply. Wrapping the already-sanitised String again reads as unaltered and
  # lets altered text pass for verified text.
  def test_mock_client_string_seed_with_an_invalid_byte_reads_as_altered_through_call_rpc_lines
    mock = RpmsRpc::MockClient.new
    rpc = RpmsRpc::DataMapper[:bmc_patient_face_sheet].rpc_name
    mock.seed_text(:bmc_patient_face_sheet, "1", INVALID.dup)
    reply = mock.call_rpc_lines(rpc, "1")
    assert(reply.all? { |l| l.encoding == Encoding::UTF_8 && l.valid_encoding? })
    assert_equal [ "caf\uFFFD SYNTHETIC" ], reply
    assert reply.altered?, "text altered at the seed must not read as unaltered"
    assert_equal [ 0 ], reply.altered_lines
  end

  def test_mock_client_multi_line_string_seed_names_the_altered_line
    mock = RpmsRpc::MockClient.new
    rpc = RpmsRpc::DataMapper[:bmc_patient_face_sheet].rpc_name
    mock.seed_text(:bmc_patient_face_sheet, "1", [ VALID_UTF8, INVALID, ASCII ].join("\n").b)
    reply = mock.call_rpc_lines(rpc, "1")
    assert_equal [ "café SYNTHETIC", "caf\uFFFD SYNTHETIC", "PLAIN SYNTHETIC" ], reply
    assert_equal [ 1 ], reply.altered_lines
  end

  def test_mock_client_valid_utf8_string_seed_reads_as_unaltered
    mock = RpmsRpc::MockClient.new
    rpc = RpmsRpc::DataMapper[:bmc_patient_face_sheet].rpc_name
    mock.seed_text(:bmc_patient_face_sheet, "1", VALID_UTF8.dup)
    reply = mock.call_rpc_lines(rpc, "1")
    assert_equal [ "café SYNTHETIC" ], reply
    refute reply.altered?
    assert_empty reply.altered_lines
  end

  def test_mock_client_plain_ascii_string_seed_reads_as_unaltered
    mock = RpmsRpc::MockClient.new
    rpc = RpmsRpc::DataMapper[:bmc_patient_face_sheet].rpc_name
    mock.seed_text(:bmc_patient_face_sheet, "1", ASCII.dup)
    reply = mock.call_rpc_lines(rpc, "1")
    assert_equal [ "PLAIN SYNTHETIC" ], reply
    refute reply.altered?
  end

  def test_mock_client_array_seed_through_call_rpc_lines_matches_the_string_seed
    mock = RpmsRpc::MockClient.new
    rpc = RpmsRpc::DataMapper[:site_info].rpc_name
    mock.seed_raw_lines(:site_info, "", [ INVALID.dup ])
    reply = mock.call_rpc_lines(rpc, "")
    assert_equal [ "caf\uFFFD SYNTHETIC" ], reply
    assert reply.altered?
    assert_equal [ 0 ], reply.altered_lines
  end

  # The same seed tagged as UTF-8 (a plain Ruby literal) must flag, not raise:
  # splitting an invalid UTF-8 String on a newline used to blow up inside the
  # mock, so host tests crashed on input production reports as altered.
  def test_mock_client_utf8_tagged_multi_line_string_seed_flags_instead_of_raising
    mock = RpmsRpc::MockClient.new
    rpc = RpmsRpc::DataMapper[:bmc_patient_face_sheet].rpc_name
    mock.seed_text(:bmc_patient_face_sheet, "1", +"ok\ncaf\xE9 X")
    reply = mock.call_rpc_lines(rpc, "1")
    assert_equal [ "ok", "caf\uFFFD X" ], reply
    assert_equal [ 1 ], reply.altered_lines
  end
end
