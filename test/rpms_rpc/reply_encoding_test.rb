# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/xwb_client"
require "rpms_rpc/bmx_client"
require "rpms_rpc/cia_client"

# rpms-rpc#463 — a reply reaches the host as valid UTF-8, and a reply whose
# bytes had to be altered says so.
#
# CHARSET: the wire carries stored bytes untranscoded (rpms-rpc#476; the live
# captures and their test are in wire_charset_test.rb), so stored Latin-1 or
# Windows-1252 text reads as altered. That is the accepted, fail-closed rule.
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
end
