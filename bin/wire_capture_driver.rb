# frozen_string_literal: true

# Client half of `rake wire:capture` (issue #189). In host mode (BROKER_HOST=,
# rpms-ops#975) the task runs it on this machine against the broker; with
# CONTAINER= it is staged into the rung container alongside rpms-rpc/lib (the
# rpms-ops evidence-script pattern) and run there. Either way it runs as:
#
#   VISTA_RPC_ENV=development RPMS_RPC_LIB=/tmp/rr/lib \
#     BROKER_HOST=127.0.0.1 BROKER_PORT=9100 \
#     RPMS_ACCESS=... RPMS_VERIFY=... ruby wire_capture_driver.rb
#
# Connects the real client (RpmsRpc::CiaClient) to the rung's broker. A read
# run calls the live catalog — read RPCs with synthetic inputs, against a
# rung we own, never a customer instance. A WRITES=1 run calls none of those.
# It prints one JSON document on stdout. The host-side rake task turns that
# into provenance-stamped fixtures. This script does not edit captured bytes.
#
# WRITES=1 (refused unless the broker host resolves to loopback, CONTAINER
# is unset, and the access code is a synthetic persona) runs NoteWriteFlow
# and does not call read RPCs: create, lock, set text, read-back, unlock,
# and sign when RPMS_ESIG is a non-blank string. The signature code is read
# from the environment only and is never printed. A capture that contains it
# is dropped, not rewritten. ONLY naming one write RPC still runs the whole
# flow, because later steps need the note IEN; the rake task writes only
# that RPC's fixture.
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
writes = ENV["WRITES"] == "1"
# Plain code only. The flow already drops a capture that holds the ciphertext.
esig_secrets = [ ENV["RPMS_ESIG"] ]

# Same gate as the rake task, before the socket. A direct run cannot skip it.
if writes
  reason = RpmsRpc::WireCapture.write_refusal(
    writes: true, host: host, container: ENV["CONTAINER"], access: acc
  )
  abort reason if reason
end

out = { "client" => "rpms-rpc RpmsRpc::CiaClient",
        "client_version" => (RpmsRpc.const_defined?(:VERSION) ? RpmsRpc::VERSION : "unversioned"),
        "captures" => {} }

client = RpmsRpc::CiaClient.new(host: host, port: port, timeout: 15)
client.connect
client.authenticate(acc, ver)

# ONLY / CITE_ONLY are applied HERE, not only host-side when fixtures are
# written. The point of CITE_ONLY is to avoid calling an RPC that faults or
# disturbs the session; filtering after the driver has already called
# everything does not achieve that.
only = ENV["ONLY"].to_s.strip
cite_only = ENV["CITE_ONLY"].to_s.split(",").map(&:strip).reject(&:empty?)

entries = RpmsRpc::WireCapture.driver_read_entries(writes: writes, only: only, cite_only: cite_only)
out["selected"] = entries.map(&:rpc)

entries.each do |entry|
  raw = client.call_rpc_raw(entry.rpc, *entry.inputs)
  raw = raw.join("\n") if raw.is_a?(Array)
  out["captures"][entry.rpc] = { "inputs" => entry.inputs, "raw" => raw.to_s }
rescue StandardError => e
  out["captures"][entry.rpc] = {
    "inputs" => entry.inputs,
    "error" => RpmsRpc::WireCapture::NoteWriteFlow.redacted_error(e, esig_secrets)
  }
end

# ONLY naming a write RPC still runs every step (the IEN comes from create).
# The rake task writes only the named fixture. ONLY naming a read does not
# create a note.
write_rpcs = RpmsRpc::WireCapture::CATALOG.select(&:write?).map(&:rpc)
if writes && (only.empty? || write_rpcs.include?(only))
  begin
    RpmsRpc::WireCapture::NoteWriteFlow.run(client, esig: ENV["RPMS_ESIG"]).each do |rpc, capture|
      out["captures"][rpc] = capture
    end
  rescue StandardError => e
    rpc = write_rpcs.include?(only) ? only : write_rpcs.first
    if rpc
      out["captures"][rpc] = {
        "error" => RpmsRpc::WireCapture::NoteWriteFlow.redacted_error(e, esig_secrets)
      }
    end
  end
end

client.disconnect
# Drop any capture that still holds the plain code, including read replies.
out["captures"] = RpmsRpc::WireCapture::NoteWriteFlow.quarantine_secrets(out["captures"], esig_secrets)
puts JSON.generate(out)
