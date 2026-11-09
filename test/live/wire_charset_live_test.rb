# frozen_string_literal: true

require_relative "live_helper"

# rpms-rpc#476 over CIA: the broker carries a stored high byte unchanged.
# Reads #8994 XWB CREATE CONTEXT's description, whose two bullets are stored as
# the single byte 0xB7, and compares the reply with the committed capture
# (test/fixtures/wire_charset/captures.yml). Reads only.
class WireCharsetLiveTest < LiveSpec::Test
  FIXTURES = File.expand_path("../fixtures/wire_charset", __dir__)
  ENTRY = YAML.safe_load_file(File.join(FIXTURES, "captures.yml")).dig("captures", "cia")

  def test_the_stored_bullet_arrives_as_one_byte_and_is_reported
    params = ENTRY["params"]
    raw = client.call_rpc_raw(ENTRY["rpc"], params).b
    body = raw.split("\x00".b, 2).fetch(1)
    captured = File.binread(File.join(FIXTURES, ENTRY["file"])).split("\x00".b, 2).fetch(1)

    assert_equal captured, body, "the description's bytes differ from the capture"
    assert_equal 2, body.count("\xB7".b)
    refute_includes body, "\xC2\xB7".b, "the broker transcoded the stored byte to UTF-8"

    reply = client.call_rpc(ENTRY["rpc"], params)
    assert reply.altered?, "a stored 0xB7 must be replaced and reported, not passed on"
    assert_equal 2, reply.altered_lines.size
  end
end
