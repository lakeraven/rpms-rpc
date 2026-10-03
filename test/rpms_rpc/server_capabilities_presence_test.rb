# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/client"
require "rpms_rpc/xwb_client"
require "rpms_rpc/cia_client"
require "rpms_rpc/bmx_client"
require "rpms_rpc/server_capabilities"

# rpms-rpc#209: a capability probe asks the broker whether an RPC is
# registered and callable; it does not call the RPC with no parameters
# (which dies with LVUNDEF and writes a server error-log entry every time).
class RpmsRpc::ServerCapabilitiesPresenceTest < Minitest::Test
  # Stub the wire on a real client class: record each call, answer from a table.
  def stub_wire(client, method, answers)
    calls = []
    client.define_singleton_method(method) do |name, *params|
      calls << [ name, *params ]
      answers.fetch([ name, *params ]) { raise "unexpected call #{[ name, *params ].inspect}" }
    end
    calls
  end

  # What each broker's check answers, and that the probe puts only the check on
  # the wire, are proven live (ADR 0009): test/live/rpc_presence_probe_live_test.rb,
  # against the CIA and the XWB broker. What stays here is client mechanics no
  # server produces on demand: which client keeps the call probe, and the
  # fall-back when the check itself errors.

  # -- BMX: CHKPRMIT^BMXMSEC exempts neither check, so BMX keeps the old probe.

  def test_bmx_keeps_calling_the_rpc
    client = RpmsRpc::BmxClient.new
    calls = stub_wire(client, :call_rpc, [ "ORWU USERKEYS" ] => "")

    assert_equal true, RpmsRpc::ServerCapabilities.rpc_present?(client, "ORWU USERKEYS")
    assert_equal [ [ "ORWU USERKEYS" ] ], calls
  end

  # -- A check RPC that errors falls back to the old probe rather than guessing.

  def test_falls_back_to_calling_the_rpc_when_the_check_errors
    client = RpmsRpc::XwbClient.new
    calls = []
    client.define_singleton_method(:call_rpc) do |name, *params|
      calls << name
      raise RpmsRpc::Client::RpcError, "Access denied" if name == "XWB IS RPC AVAILABLE"

      ""
    end

    assert_equal true, RpmsRpc::ServerCapabilities.rpc_present?(client, "ORWU USERKEYS")
    assert_equal [ "XWB IS RPC AVAILABLE", "ORWU USERKEYS" ], calls
  end
end
