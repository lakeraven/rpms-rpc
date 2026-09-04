# frozen_string_literal: true

# In-container half of `rake wire:capture` (issue #189). Staged into the rung
# container alongside rpms-rpc/lib (the rpms-ops evidence-script pattern —
# rpms-ops/bin/rpms_rpc_evidence.sh) and run with:
#
#   VISTA_RPC_ENV=development RPMS_RPC_LIB=/tmp/rr/lib \
#     BROKER_HOST=127.0.0.1 BROKER_PORT=9100 \
#     RPMS_ACCESS=... RPMS_VERIFY=... ruby /tmp/rr_driver.rb
#
# Connects the real client (RpmsRpc::CiaClient) to the rung's broker, calls
# every LIVE-mode entry in RpmsRpc::WireCapture::CATALOG — read-only
# behavioral RPCs with synthetic inputs, against a rung we own, never a
# customer instance — and prints one JSON document on stdout. The host-side
# rake task turns that into provenance-stamped fixtures. This script never
# writes to the target and never edits captured bytes.
require "json"

# rpms-rpc references IO::TimeoutError (Ruby >= 3.2); container rubies can be
# older (see rpms-ops#440). Alias keeps the rescue paths valid.
IO::TimeoutError = Class.new(IOError) unless IO.const_defined?(:TimeoutError)

lib = ENV["RPMS_RPC_LIB"] or abort("set RPMS_RPC_LIB to rpms-rpc/lib")
$LOAD_PATH.unshift(lib)
require "rpms_rpc/version"
require "rpms_rpc/cia_client"
require "rpms_rpc/wire_capture"

host = ENV.fetch("BROKER_HOST", "127.0.0.1")
port = ENV.fetch("BROKER_PORT", "9100").to_i
acc = ENV.fetch("RPMS_ACCESS", "SYS123")
ver = ENV.fetch("RPMS_VERIFY", "RPMS.000")

out = { "client" => "rpms-rpc RpmsRpc::CiaClient",
        "client_version" => (RpmsRpc.const_defined?(:VERSION) ? RpmsRpc::VERSION : "unversioned"),
        "captures" => {} }

client = RpmsRpc::CiaClient.new(host: host, port: port, timeout: 15)
client.connect
client.authenticate(acc, ver)

RpmsRpc::WireCapture::CATALOG.select(&:live?).each do |entry|
  raw = client.call_rpc_raw(entry.rpc, *entry.inputs)
  raw = raw.join("\n") if raw.is_a?(Array)
  out["captures"][entry.rpc] = { "inputs" => entry.inputs, "raw" => raw.to_s }
rescue StandardError => e
  out["captures"][entry.rpc] = { "inputs" => entry.inputs,
                                 "error" => "#{e.class}: #{e.message}" }
end

client.disconnect
puts JSON.generate(out)
