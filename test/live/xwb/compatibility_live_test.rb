# frozen_string_literal: true

require_relative "../live_helper"
require "rpms_rpc/compatibility"

# client.compatibility over XWB (rpms-rpc#366, acceptance 5): once signed on, one XWB IS RPC AVAILABLE
# per RPC asks the server (CPRS's check), and the report names each RPC this release sends that the server
# does not serve, by API module.
#
#   - on the pinned build, nothing is missing: the callable gate (callable_rpc_names_test.rb)
#     holds every RPC the API sends to the pinned registry offline, and this proves the server
#     answers the same;
#   - an RPC the build does not register is reported, under the module that names it, and the
#     strict form raises naming it.
#
# Read only: XWB IS RPC AVAILABLE reads #8994; nothing is filed.
class CompatibilityXwbLiveTest < LiveSpec::Test
  broker :xwb
  # Registered on no pinned registry (#207); the gem no longer sends it.
  UNREGISTERED_RPC = "ORWU USERKEYS"
  SERVED_RPC = "ORWPT SELECT"

  def test_the_pinned_build_serves_every_rpc_this_release_sends
    report = client.compatibility
    assert_predicate report, :ok?, report.to_s
    assert_operator report.required.values.flatten.uniq.size, :>, 100, "the release's list is too short to be the API's"
  end

  def test_an_rpc_the_build_does_not_register_is_reported_by_name
    required = { "build" => "live", "modules" => { "RpmsRpc::Probe" => [ SERVED_RPC, UNREGISTERED_RPC ] } }
    report = RpmsRpc::Compatibility.check(client, required: required)

    assert_equal({ "RpmsRpc::Probe" => [ UNREGISTERED_RPC ] }, report.missing)
    err = assert_raises(RpmsRpc::Compatibility::MissingRpcsError) { RpmsRpc::Compatibility.check(client, strict: true, required: required) }
    assert_match(/RpmsRpc::Probe: #{UNREGISTERED_RPC}/, err.message)
  end

  # XWB IS RPC AVAILABLE runs in any context (XWBSEC.m:14), so any signed-on persona may ask,
  # and the asking leaves the session usable.
  def test_the_check_leaves_the_session_usable
    client.compatibility
    refute_empty client.call_rpc("XUS GET USER INFO"), "the next RPC on the session did not answer"
  end
end
