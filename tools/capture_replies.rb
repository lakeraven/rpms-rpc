# frozen_string_literal: true

# Capture broker replies verbatim from a throwaway container of a pinned build
# into test/fixtures/captured_replies/<slug>.yml, sealed by sha256, for tests
# that replay them through CiaClient (test/rpms_rpc/captured_replies.rb).
#
#   docker run --detach --name <name> --publish 127.0.0.1:<port>:9100 <image>
#   LIVE_BUILD=<release tag> LIVE_IMAGE=<image@sha256:...> BROKER_PORT=<port> \
#     bundle exec ruby -Ilib tools/capture_replies.rb tools/captured_replies/<slug>.rb
#   docker rm -f <name>
#
# A spec file defines CAPTURE: the RPC, the persona's published demo pair, the
# context to bind, and the calls. A refused call aborts the run (nothing is
# written) unless it sets expect_error: true. A call's `inputs` are what the fixture
# records; `wire_inputs`, when given, computes what is sent (an encrypted
# code), so a secret-shaped input never lands in the fixture. Loopback only.
require "yaml"
require "digest"
require "time"
require "rpms_rpc/mappings"
require "rpms_rpc/cia_client"
require "rpms_rpc/valid_signature"

spec_path = ARGV.fetch(0) { abort "usage: capture_replies.rb tools/captured_replies/<slug>.rb" }
load spec_path
spec = CAPTURE
slug = File.basename(spec_path, ".rb")
out = File.expand_path("../test/fixtures/captured_replies/#{slug}.yml", __dir__)
build = ENV.fetch("LIVE_BUILD") { abort "LIVE_BUILD (the release tag of the container) is required" }
image = ENV.fetch("LIVE_IMAGE") { abort "LIVE_IMAGE (the image, by digest) is required" }

client = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: Integer(ENV.fetch("BROKER_PORT", "9100")), timeout: 30)
client.connect
client.authenticate(spec.fetch(:access), spec.fetch(:verify))
client.create_context(spec[:context]) if spec[:context]
spec.fetch(:setup, nil)&.call(client)
captures = spec.fetch(:calls).map do |call|
  wire = call[:wire_inputs] ? call[:wire_inputs].call(client) : call.fetch(:inputs)
  raw = client.call_rpc_raw(call.fetch(:rpc, spec[:rpc]), *wire).b
  # call_rpc_raw returns a refusal's bytes without raising. A capture that is
  # an error reply ($C(1) after the sequence echo) writes nothing, unless the
  # spec says that call is meant to capture the error (expect_error: true).
  if raw.getbyte(1) == 0x01 && !call[:expect_error]
    abort "#{call.fetch(:name)}: the broker answered an error, not data: #{raw.byteslice(2..).inspect}; nothing written"
  end
  entry = { "name" => call.fetch(:name) }
  entry["rpc"] = call[:rpc] if call[:rpc]
  entry.merge("inputs" => call.fetch(:inputs), "context" => call.fetch(:about),
              "raw_return" => raw.dup.force_encoding(Encoding::UTF_8), "sha256" => Digest::SHA256.hexdigest(raw))
end
client.disconnect

doc = {
  "rpc" => spec.fetch(:rpc), "entry_point" => spec.fetch(:entry_point),
  "release_tag" => build, "image" => image,
  "client" => "RpmsRpc::CiaClient#call_rpc_raw",
  "signed_on_as" => spec.fetch(:signed_on_as),
  "bound_context" => spec[:context] || RpmsRpc::CiaClient::SIGNON_CONTEXT,
  "captured_at" => Time.now.utc.iso8601, "note" => spec.fetch(:note), "captures" => captures
}
File.write(out, "# Captured broker replies, verbatim from a throwaway container of the release below; synthetic\n" \
                "# demo data only. Do not edit raw_return: re-run tools/capture_replies.rb #{File.basename(spec_path)}.\n" + doc.to_yaml)
puts "wrote #{out} (#{captures.size} captures)"
