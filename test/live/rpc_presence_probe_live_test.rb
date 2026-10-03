# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/server_capabilities"

# A capability probe asks the broker whether an RPC is registered and
# callable; it never runs the RPC (#209). Running it with no parameters died
# with LVUNDEF (BEHOPTCX PTINFO: DFN) and wrote a server error-log entry on
# every probe. Each broker has its own check, exempt from the context gate:
#
#   CIA  CIANBRPC CANRUN (CANRUN^CIANBRPC), exempt as a CIANB* routine
#        (CIANBACT.m:49); it answers a $D count, 10 for a registered RPC
#        (1 for an XUPROGMODE holder), 0 for none.
#   XWB  XWB IS RPC AVAILABLE (CKRPC^XWBLIB), on the any-context list
#        (XWBSEC.m:14); it answers 1 or 0.
#
# BMX has no such check and keeps the call probe; that dispatch, and the
# fall-back when a check errors, are client mechanics tested by hand in
# test/rpms_rpc/server_capabilities_presence_test.rb.
#
# These specs read only; they file nothing.
module RpcPresenceProbeLive
  # Registered on the pinned build; BEHOPTCX PTINFO dies with LVUNDEF DFN
  # when called with no parameters, which is what the old probe did.
  REGISTERED = [ "ORWU USERINFO", "BEHOPTCX PTINFO" ].freeze
  UNKNOWN = "ZZ NO SUCH RPC 209"

  def test_a_registered_rpc_reads_present_and_an_unknown_name_absent
    REGISTERED.each { |rpc| assert RpmsRpc::ServerCapabilities.rpc_present?(client, rpc), "#{rpc} read as absent" }
    refute RpmsRpc::ServerCapabilities.rpc_present?(client, UNKNOWN), "#{UNKNOWN} read as present"
  end

  def test_the_probe_sends_only_the_check_never_the_probed_rpc
    REGISTERED.each do |rpc|
      sent = record_wire { RpmsRpc::ServerCapabilities.rpc_present?(client, rpc) }
      assert_equal [ check_rpc ], sent, "probing #{rpc} put more than the check on the wire"
    end
  end

  def test_the_check_answers_from_the_registry
    REGISTERED.each { |rpc| assert_includes present_answers, raw_check(rpc), "#{check_rpc} on #{rpc}" }
    assert_equal "0", raw_check(UNKNOWN), "#{check_rpc} on #{UNKNOWN}"
  end

  private

  # The RPC names this client puts on the wire while the block runs.
  def record_wire
    sent = []
    method = wire_method
    spy = Module.new do
      define_method(method) do |name, *rest|
        sent << name
        super(name, *rest)
      end
    end
    client.singleton_class.prepend(spy)
    yield
    sent
  end
end

class CiaRpcPresenceProbeLiveTest < LiveSpec::Test
  include RpcPresenceProbeLive

  # Why CIA needs its own check: the CIA broker's context gate exempts only
  # CIANB* routines (CIANBACT.m:49), so it refuses XWB IS RPC AVAILABLE to a
  # user without programmer mode. An XUPROGMODE holder (CANRUN answers 1, not
  # 10) passes the gate, and the XWB check then answers.
  def test_the_cia_broker_refuses_the_xwb_check_unless_the_user_is_a_programmer
    if raw_check("ORWU USERINFO") == "1"
      assert_equal [ "1" ], client.call_rpc("XWB IS RPC AVAILABLE", "ORWU USERINFO", "R").map(&:strip),
                   "#{persona} holds programmer mode, so the gate lets the XWB check through"
    else
      err = assert_raises(RpmsRpc::Client::RpcError) { client.call_rpc("XWB IS RPC AVAILABLE", "ORWU USERINFO", "R") }
      assert_match(/Access denied/i, err.message)
    end
  end

  private

  def check_rpc = "CIANBRPC CANRUN"
  def wire_method = :call_rpc_raw # every CIA RPC, call_rpc included, goes through it
  def present_answers = %w[10 1]
  def raw_check(rpc) = client.call_rpc(check_rpc, rpc).first.to_s.strip
end

class XwbRpcPresenceProbeLiveTest < LiveSpec::Test
  include RpcPresenceProbeLive
  broker :xwb

  private

  def check_rpc = "XWB IS RPC AVAILABLE"
  def wire_method = :build_rpc_message # call_rpc and call_rpc_raw both frame here
  def present_answers = %w[1]
  def raw_check(rpc) = Array(client.call_rpc(check_rpc, rpc, "R")).first.to_s.strip
end
