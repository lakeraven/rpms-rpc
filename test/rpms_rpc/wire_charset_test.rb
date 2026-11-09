# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "yaml"
require "rpms_rpc/bmx_client"
require "rpms_rpc/cia_client"

# rpms-rpc#476: the wire carries stored bytes as they are, and a stored high
# byte that is not UTF-8 is replaced and reported, never passed on silently.
#
# The inputs are live captures (test/fixtures/wire_charset/captures.yml): the
# raw reply bytes of #8994 XWB CREATE CONTEXT's description, read over CIA and
# over BMX on a released build. Its two bullets are stored as the single byte
# 0xB7. Nothing here is hand-written bytes.
class RpmsRpc::WireCharsetTest < Minitest::Test
  DIR = File.expand_path("../fixtures/wire_charset", __dir__)
  MANIFEST = YAML.safe_load_file(File.join(DIR, "captures.yml"))
  BULLET = "\xB7".b
  BULLET_LINE = "       \xB7 The user has no access to that option".b

  class FakeSocket
    def initialize(reads) = (@reads = reads.dup)
    def write(str) = str.bytesize
    def recv(_n) = @reads.empty? ? "" : @reads.shift.b
    def flush; end
    def close = @closed = true
    def closed? = !!@closed
    def setsockopt(*); end
  end

  def capture(transport) = File.binread(File.join(DIR, MANIFEST.dig("captures", transport, "file")))

  # The CIA capture is the seq echo and NUL ack, then the body.
  def cia_body = capture("cia").split("\x00".b, 2).fetch(1)

  def wired(client, reads)
    client.instance_variable_set(:@socket, FakeSocket.new(reads))
    client.instance_variable_set(:@connected, true)
    client.instance_variable_set(:@timeout, 1)
    client
  end

  def cia_reply
    client = wired(RpmsRpc::CiaClient.new, [ "1\x00".b + cia_body + RpmsRpc::Client::EOD ])
    client.instance_variable_set(:@seq, 0)
    client.call_rpc("DDR GETS ENTRY DATA")
  end

  def bmx_reply
    wired(RpmsRpc::BmxClient.new, [ "\x00\x00".b + capture("bmx") + RpmsRpc::Client::EOT ]).call_rpc("BMX SQL")
  end

  %w[cia bmx].each do |transport|
    define_method("test_the_#{transport}_capture_is_the_recorded_bytes") do
      entry = MANIFEST.dig("captures", transport)
      bytes = capture(transport)
      assert_equal entry["bytes"], bytes.bytesize
      assert_equal entry["sha256"], Digest::SHA256.hexdigest(bytes)
    end

    define_method("test_#{transport}_carries_the_stored_byte_untranscoded") do
      bytes = capture(transport)
      assert_equal 2, bytes.count(BULLET), "the description stores two 0xB7 bullets"
      assert_includes bytes, BULLET_LINE
      refute_includes bytes, "\xC2\xB7".b, "a UTF-8 middle dot would mean the broker transcoded"
      refute bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?
    end
  end

  def test_cia_replaces_and_reports_only_the_bullet_lines
    assert_replaced_and_reported(cia_reply, cia_body.split("\r".b))
  end

  def test_bmx_replaces_and_reports_only_the_bullet_lines
    reply = bmx_reply
    assert_operator reply.size, :>, 1, "the header row and the description: #{reply.inspect}"
    assert reply.altered?
    raw_lines = capture("bmx").split(/[\x1e\x1f]/n)
    bullets = reply.each_index.select { |i| reply[i].include?("�") }
    assert_equal reply.altered_lines, bullets
    assert_equal 1, bullets.size, "BMX SQL returns the description as one row: #{reply.inspect}"
    row = raw_lines.find { |l| l.include?(BULLET) }
    assert_equal row.gsub(BULLET, "�".b).force_encoding(Encoding::UTF_8), reply[bullets.first]
  end

  private

  def assert_replaced_and_reported(reply, raw_lines)
    assert reply.altered?
    reply.each { |line| assert line.valid_encoding?, line.inspect }
    expected_altered = []
    raw_lines.each_with_index do |raw, i|
      if raw.include?(BULLET)
        expected_altered << i
        assert_equal raw.gsub(BULLET, "�".b).force_encoding(Encoding::UTF_8), reply[i]
      else
        assert_equal raw.dup.force_encoding(Encoding::UTF_8), reply[i]
      end
    end
    assert_equal 2, expected_altered.size
    assert_equal expected_altered, reply.altered_lines
  end
end
