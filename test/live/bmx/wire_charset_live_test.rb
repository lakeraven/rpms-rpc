# frozen_string_literal: true

require_relative "../live_helper"

# rpms-rpc#476 over BMX: the broker carries a stored high byte unchanged.
# Reads #8994 XWB CREATE CONTEXT's description through BMX SQL and compares the
# reply with the committed capture (test/fixtures/wire_charset/captures.yml).
# Needs the BMXRPC context. Reads only.
#   BROKER_PROTOCOL=bmx BROKER_PORT=<the image's 9101> rake test:live
class BmxWireCharsetLiveTest < LiveSpec::Test
  broker :bmx

  FIXTURES = File.expand_path("../../fixtures/wire_charset", __dir__)
  ENTRY = YAML.safe_load_file(File.join(FIXTURES, "captures.yml")).dig("captures", "bmx")

  def setup
    super
    client.create_context(ENTRY["context"])
  rescue RpmsRpc::Client::RpcError => e
    flunk "#{persona} cannot bind #{ENTRY['context']} on this build (#{e.message}): BMX SQL is registered there"
  end

  def test_the_stored_bullet_arrives_as_one_byte_and_is_reported
    raw = client.call_rpc_raw(ENTRY["rpc"], *ENTRY["params"]).b

    assert_equal File.binread(File.join(FIXTURES, ENTRY["file"])), raw, "the description's bytes differ from the capture"
    assert_equal 2, raw.count("\xB7".b)
    refute_includes raw, "\xC2\xB7".b, "the broker transcoded the stored byte to UTF-8"

    reply = client.call_rpc(ENTRY["rpc"], *ENTRY["params"])
    assert reply.altered?, "a stored 0xB7 must be replaced and reported, not passed on"
  end
end
