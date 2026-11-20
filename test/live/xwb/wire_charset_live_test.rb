# frozen_string_literal: true

require_relative "../live_helper"

# rpms-rpc#659 over XWB: the broker carries a stored high byte unchanged on IRIS.
# Reads #8994 XWB CREATE CONTEXT's description, whose two bullets are stored as
# the single byte 0xB7, and compares the reply with the committed capture
# (test/fixtures/wire_charset/captures.yml). Binds CIAV VUECENTRIC, the option
# that serves the DDR read family. Reads only.
#   BROKER_PROTOCOL=xwb BROKER_PORT=<the IRIS build's 9100> rake test:live
class XwbWireCharsetLiveTest < LiveSpec::Test
  runs_as "PROV123"
  broker :xwb

  FIXTURES = File.expand_path("../../fixtures/wire_charset", __dir__)
  ENTRY = YAML.safe_load_file(File.join(FIXTURES, "captures.yml")).dig("captures", "xwb")

  def setup
    super
    flunk "#{persona} cannot bind #{ENTRY['context']} over XWB on this build" unless client.create_context(ENTRY["context"])
  end

  def test_the_stored_bullet_arrives_as_one_byte_and_is_reported
    params = ENTRY["params"]
    raw = client.call_rpc_raw(ENTRY["rpc"], params).b

    assert_equal File.binread(File.join(FIXTURES, ENTRY["file"])), raw, "the description's bytes differ from the capture"
    assert_equal 2, raw.count("\xB7".b)
    refute_includes raw, "\xC2\xB7".b, "the broker transcoded the stored byte to UTF-8"

    reply = client.call_rpc(ENTRY["rpc"], params)
    assert reply.altered?, "a stored 0xB7 must be replaced and reported, not passed on"
    assert_equal 2, reply.altered_lines.size
  end
end
