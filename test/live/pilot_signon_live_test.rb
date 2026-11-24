# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/notifications"

# Signing on as the medical assistant (openrpms-ux S-SGN-01): with the role's
# own access and verify codes the session opens, names the user and the
# division it acts in, and answers the Notifications list the EHR opens on;
# with a wrong verify code sign-on is refused, and the session answers no
# chart RPC. Reads only.
class PilotSignonLiveTest < LiveSpec::Test
  runs_as :medical_assistant
  proves "S-SGN-01.1", "S-SGN-01.2"
  connect_only!

  def test_valid_codes_open_on_notifications_with_my_name_and_division
    result = client.authenticate(*sign_on_pair)

    assert result[:success], result.inspect
    assert_equal role_row.account, result[:user]
    assert_includes client.divisions.map { |d| d[:ien] }, result[:division]
    refute_empty client.division[:name].to_s, "the division has a name to show: #{client.division.inspect}"
    RpmsRpc.configure { |cfg| cfg.client = client }
    assert_kind_of Array, RpmsRpc::Notifications.inbox, "the Notifications list answers"
  end

  def test_a_wrong_verify_code_is_refused_and_opens_nothing
    access, = sign_on_pair
    error = assert_raises(RpmsRpc::Client::AuthenticationError) { client.authenticate(access, "WRONG#{rand(1000)}!!") }
    assert_match(/not a valid ACCESS CODE\/VERIFY CODE pair/i, error.message)

    assert_raises(RpmsRpc::Client::RpcRefusedError) { client.call_rpc("BEHOSICX SITEINFO") }
  end
end
