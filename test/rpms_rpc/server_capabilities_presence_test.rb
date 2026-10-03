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

  # -- XWB: XWB IS RPC AVAILABLE (CKRPC^XWBLIB), exempt from context at XWBSEC.m:14

  def test_xwb_asks_xwb_is_rpc_available_and_never_calls_the_probed_rpc
    client = RpmsRpc::XwbClient.new
    calls = stub_wire(client, :call_rpc,
      [ "XWB IS RPC AVAILABLE", "ORWU USERKEYS", "R" ] => [ "1" ])

    assert_equal true, RpmsRpc::ServerCapabilities.rpc_present?(client, "ORWU USERKEYS")
    assert_equal [ [ "XWB IS RPC AVAILABLE", "ORWU USERKEYS", "R" ] ], calls
  end

  def test_xwb_answers_absent_for_zero
    client = RpmsRpc::XwbClient.new
    stub_wire(client, :call_rpc, [ "XWB IS RPC AVAILABLE", "ZZ NO SUCH RPC", "R" ] => [ "0" ])

    assert_equal false, RpmsRpc::ServerCapabilities.rpc_present?(client, "ZZ NO SUCH RPC")
  end

  # -- CIA: CIANBRPC CANRUN (CANRUN^CIANBRPC). The CIA broker refuses XWB IS RPC
  # AVAILABLE ("Access denied", CIANBACT.m:49 exempts only CIANB* routines).

  def test_cia_asks_cianbrpc_canrun_and_never_calls_the_probed_rpc
    client = RpmsRpc::CiaClient.new
    # $D(^XTMP("CIA",UID,"C",CTX,RPC)) = 10 for a non-programmer (live, 2026-10-03)
    calls = stub_wire(client, :call_rpc_raw,
      [ "CIANBRPC CANRUN", "BEHOPTCX PTINFO" ] => "5\x0010")

    assert_equal true, RpmsRpc::ServerCapabilities.rpc_present?(client, "BEHOPTCX PTINFO")
    assert_equal [ [ "CIANBRPC CANRUN", "BEHOPTCX PTINFO" ] ], calls
  end

  def test_cia_answers_present_for_programmer_one
    client = RpmsRpc::CiaClient.new
    stub_wire(client, :call_rpc_raw, [ "CIANBRPC CANRUN", "ORWU USERINFO" ] => "4\x001")

    assert_equal true, RpmsRpc::ServerCapabilities.rpc_present?(client, "ORWU USERINFO")
  end

  def test_cia_answers_absent_for_zero
    client = RpmsRpc::CiaClient.new
    stub_wire(client, :call_rpc_raw, [ "CIANBRPC CANRUN", "ZZ NO SUCH RPC" ] => "6\x000")

    assert_equal false, RpmsRpc::ServerCapabilities.rpc_present?(client, "ZZ NO SUCH RPC")
  end

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
