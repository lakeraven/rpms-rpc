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
# run calls every LIVE-mode entry in RpmsRpc::WireCapture::CATALOG — read RPCs
# with synthetic inputs, against a rung we own, never a customer instance. An
# entry that names a context option is called inside client.with_context, so
# the broker sees that option (AGG LOOKUP PATIENTS is registered under AGGRPC
# only). A WRITES=1 run calls none of those.
# It prints one JSON document on stdout. The host-side rake task turns that
# into provenance-stamped fixtures. This script does not edit captured bytes.
#
# WRITES=1 runs NoteWriteFlow and does not call read RPCs: create, lock,
# set text, read-back, unlock, and sign when the read-back is evidence and
# RPMS_ESIG was supplied. It is refused before the socket unless the broker
# host resolves to loopback, CONTAINER is unset, the access code is a
# synthetic persona, ONLY is blank (the TIU flow is captured together), and
# RPMS_ESIG is unset or 6-20 characters with no leading or trailing
# whitespace (field 20.4 stores the exact code). A write run dials the
# resolved loopback address, not the host name. The signature code is read
# from the environment only and is never printed. A capture that contains
# it is dropped, not rewritten.
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
# Judged before the socket. A blank ONLY is unset; a write run captures the TIU flow as one unit.
only = RpmsRpc::WireCapture.normalize_only(ENV["ONLY"])
cite_only = ENV["CITE_ONLY"].to_s.split(",").map(&:strip).reject(&:empty?)
# Plain code only. The flow already drops a capture that holds the ciphertext.
esig = ENV["RPMS_ESIG"]
esig_secrets = [ esig ]

# Same gate as the rake task, before the socket. A direct run cannot skip it.
# Read runs keep the host name. A write run dials the loopback address it checked.
connect_host = host
if writes
  reason = RpmsRpc::WireCapture.write_refusal(
    writes: true, host: host, container: ENV["CONTAINER"], access: acc,
    only: only, esig: esig
  )
  abort reason if reason

  connect_host = RpmsRpc::WireCapture.write_connect_host(host: host)
  # Fail closed: a name that does not resolve to loopback must not be dialed.
  abort "WRITES=1 is refused unless the broker host resolves to loopback addresses only" if connect_host.nil?
end

out = { "client" => "rpms-rpc RpmsRpc::CiaClient",
        "client_version" => (RpmsRpc.const_defined?(:VERSION) ? RpmsRpc::VERSION : "unversioned"),
        "captures" => {} }

client = RpmsRpc::CiaClient.new(host: connect_host, port: port, timeout: 15)
client.connect
client.authenticate(acc, ver)

# ONLY / CITE_ONLY narrow read captures here, not only when fixtures are
# written. The point of CITE_ONLY is to avoid calling an RPC that faults or
# disturbs the session; filtering after the driver has already called
# everything does not achieve that. A write run has already refused ONLY.
entries = RpmsRpc::WireCapture.driver_read_entries(writes: writes, only: only, cite_only: cite_only)
out["selected"] = entries.map(&:rpc)

entries.each do |entry|
  raw = if entry.context
          client.with_context(entry.context) { client.call_rpc_raw(entry.rpc, *entry.inputs) }
        else
          client.call_rpc_raw(entry.rpc, *entry.inputs)
        end
  raw = raw.join("\n") if raw.is_a?(Array)
  out["captures"][entry.rpc] = { "inputs" => entry.inputs, "raw" => raw.to_s }
rescue StandardError => e
  out["captures"][entry.rpc] = {
    "inputs" => entry.inputs,
    "error" => RpmsRpc::WireCapture::NoteWriteFlow.redacted_error(e, esig_secrets)
  }
end

# ONLY was refused above. The note flow runs as one unit, or not at all.
if writes
  begin
    RpmsRpc::WireCapture::NoteWriteFlow.run(client, esig: esig).each do |rpc, capture|
      out["captures"][rpc] = capture
    end
  rescue StandardError => e
    # A failure before any step has no RPC of its own. Record it on the first
    # write entry so the code is still redacted and the run does not look empty.
    rpc = RpmsRpc::WireCapture::CATALOG.find(&:write?)&.rpc
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
