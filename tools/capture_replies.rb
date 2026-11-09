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
# written) unless it sets expect_error: true. A call's `context:` binds that
# option before it, for the rest of the run. A call's `inputs` are what the fixture
# records; `wire_inputs`, when given, computes what is sent (an encrypted
# code), so a secret-shaped input never lands in the fixture. `setup`, when
# given, runs first on the default session and returns state (say, a note it
# made) that an `inputs` lambda reads. A call with `as:` runs on its own
# session, signed on as that entry of `personas`. Loopback only.
require "yaml"
require "digest"
require "time"
require "rpms_rpc/mappings"
require "rpms_rpc/cia_client"
require "rpms_rpc/valid_signature"

# A reply that is valid UTF-8 is written as text, so a fixture reads as the
# wire did. One that is not (a FileMan \xFE delimiter, say) is written as
# YAML !binary: forcing it to UTF-8 would make an invalid string Psych cannot
# dump. Either way CapturedReplies reads the bytes back with #b.
def yaml_bytes(raw)
  text = raw.dup.force_encoding(Encoding::UTF_8)
  text.valid_encoding? ? text : raw
end

spec_path = ARGV.fetch(0) { abort "usage: capture_replies.rb tools/captured_replies/<slug>.rb" }
load spec_path
spec = CAPTURE
slug = File.basename(spec_path, ".rb")
out = File.expand_path("../test/fixtures/captured_replies/#{slug}.yml", __dir__)
build = ENV.fetch("LIVE_BUILD") { abort "LIVE_BUILD (the release tag of the container) is required" }
image = ENV.fetch("LIVE_IMAGE") { abort "LIVE_IMAGE (the image, by digest) is required" }

sessions = Hash.new do |opened, who|
  pair = who == :default ? spec : spec.fetch(:personas).fetch(who)
  session = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: Integer(ENV.fetch("BROKER_PORT", "9100")), timeout: 30)
  session.connect
  session.authenticate(pair.fetch(:access), pair.fetch(:verify))
  session.create_context(spec[:context]) if spec[:context] && who == :default
  opened[who] = session
end
state = spec.fetch(:setup, nil)&.call(sessions[:default]) || {}
captures = spec.fetch(:calls).map do |call|
  client = sessions[call.fetch(:as, :default)]
  client.create_context(call[:context]) if call[:context]
  inputs = call.fetch(:inputs)
  inputs = inputs.call(state) if inputs.respond_to?(:call)
  wire = if call[:wire_inputs]
    call[:wire_inputs].arity == 2 ? call[:wire_inputs].call(client, state) : call[:wire_inputs].call(client)
  else
    inputs
  end
  raw = client.call_rpc_raw(call.fetch(:rpc, spec[:rpc]), *wire).b
  # call_rpc_raw returns a refusal's bytes without raising. A capture that is
  # an error reply ($C(1) after the sequence echo) writes nothing, unless the
  # spec says that call is meant to capture the error (expect_error: true).
  if raw.getbyte(1) == 0x01 && !call[:expect_error]
    abort "#{call.fetch(:name)}: the broker answered an error, not data: #{raw.byteslice(2..).inspect}; nothing written"
  end
  entry = { "name" => call.fetch(:name) }
  entry["rpc"] = call[:rpc] if call[:rpc]
  entry["signed_on_as"] = spec.fetch(:personas).fetch(call[:as]).fetch(:signed_on_as) if call[:as]
  entry.merge("inputs" => inputs, "context" => call.fetch(:about),
              "raw_return" => yaml_bytes(raw), "sha256" => Digest::SHA256.hexdigest(raw))
end
sessions.each_value(&:disconnect)

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
