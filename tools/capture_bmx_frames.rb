# frozen_string_literal: true

# Capture BMX reply frames verbatim (every byte the broker wrote for one call:
# len(security)+security, len(application)+application, data, EOT) from a
# throwaway container of a pinned build into test/fixtures/bmx/<slug>.yml,
# each sealed by sha256, for tests that replay them through BmxClient.
#
#   docker run --detach --name <name> --publish 127.0.0.1:<port>:9101 <image>
#   LIVE_BUILD=<release tag> LIVE_IMAGE=<image@sha256:...> BMX_PORT=<port> \
#     bundle exec ruby -Ilib tools/capture_bmx_frames.rb tools/captured_frames/<slug>.rb
#   docker rm -f <name>
#
# A spec file defines CAPTURE: the persona's published demo pair, the context
# to bind, and the calls (rpc, inputs). A call the broker answers with an
# error still records its frame: the frame is the evidence. Loopback only.
require "yaml"
require "digest"
require "time"
require "rpms_rpc/bmx_client"

spec_path = ARGV.fetch(0) { abort "usage: capture_bmx_frames.rb tools/captured_frames/<slug>.rb" }
load spec_path
spec = CAPTURE
slug = File.basename(spec_path, ".rb")
out = File.expand_path("../test/fixtures/bmx/#{slug}.yml", __dir__)
build = ENV.fetch("LIVE_BUILD") { abort "LIVE_BUILD (the release tag of the container) is required" }
image = ENV.fetch("LIVE_IMAGE") { abort "LIVE_IMAGE (the image, by digest) is required" }

client = RpmsRpc::BmxClient.new(host: "127.0.0.1", port: Integer(ENV.fetch("BMX_PORT", "9101")), timeout: 30)
client.connect
client.authenticate(spec.fetch(:access), spec.fetch(:verify))
client.create_context(spec.fetch(:context))
# The signed-on identity, read now: a call that raises a ConnectionError (a
# security packet) resets the session and forgets it.
plain = ->(division) { division&.transform_keys(&:to_s) }
identity = { "duz" => client.duz.to_s, "division" => plain.(client.division), "divisions" => Array(client.divisions).map(&plain) }

# Tee the socket's reads: what one call receives is its frame.
received = "".b
socket = client.instance_variable_get(:@socket)
recv = socket.method(:recv)
socket.define_singleton_method(:recv) do |*args|
  chunk = recv.call(*args)
  received << chunk.b if chunk
  chunk
end

frames = spec.fetch(:calls).map do |call|
  received.clear
  outcome = begin
    "reply: #{client.call_rpc(call.fetch(:rpc), *call.fetch(:inputs)).to_a.inspect}"
  rescue RpmsRpc::Error => e
    "raised #{e.class.name}"
  end
  frame = received.dup
  abort "#{call.fetch(:name)}: no EOT-terminated frame was read" unless frame.end_with?("\x04")
  { "name" => call.fetch(:name), "rpc" => call.fetch(:rpc), "inputs" => call.fetch(:inputs),
    "context" => call.fetch(:about), "outcome" => outcome,
    "frame" => frame.dup.force_encoding(Encoding::UTF_8), "sha256" => Digest::SHA256.hexdigest(frame) }
end
client.disconnect

doc = {
  "release_tag" => build, "image" => image, "client" => "RpmsRpc::BmxClient (socket reads, per call)",
  "signed_on_as" => spec.fetch(:signed_on_as), **identity, "bound_context" => spec.fetch(:context),
  "captured_at" => Time.now.utc.iso8601, "note" => spec.fetch(:note), "frames" => frames
}
File.write(out, "# BMX reply frames, verbatim from a throwaway container of the release below; synthetic\n" \
                "# demo data only. Do not edit a frame: re-run tools/capture_bmx_frames.rb #{File.basename(spec_path)}.\n" + doc.to_yaml)
puts "wrote #{out} (#{frames.size} frames)"
