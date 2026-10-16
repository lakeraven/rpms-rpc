# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/compatibility"

# client.compatibility over CIA (rpms-rpc#366, acceptance 5): once signed on, a paged DDR LISTER of
# REMOTE PROCEDURE (#8994) reads the server's registry, and the report names each RPC this release
# sends that the server does not serve, by API module.
#
#   - on the pinned build, nothing is missing: the callable gate (callable_rpc_names_test.rb)
#     holds every RPC the API sends to the pinned registry offline, and this proves the server
#     answers the same;
#   - an RPC the build does not register is reported, under the module that names it, and the
#     strict form raises naming it.
#
# Read only: DDR LISTER lists #8994; nothing is filed.
class CompatibilityLiveTest < LiveSpec::Test
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

  # The registry read runs in the sign-on option (CIAV VUECENTRIC, which lists DDR LISTER), as any
  # persona that can sign on to VueCentric may, and leaves the session in the option it found.
  def test_the_check_leaves_the_session_usable
    before = client.current_context
    client.compatibility
    assert_equal before, client.current_context, "the check left the session in another option"
    refute_empty client.call_rpc("ORWU USERINFO"), "the next RPC on the session did not answer"
  end
end
