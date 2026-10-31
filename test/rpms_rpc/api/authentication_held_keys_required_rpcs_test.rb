# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc/compatibility"

# held_keys must ask ORWU NPHASKEY (OR CPRS GUI CHART), not VueCentric-only
# CIAVCXUS HASKEYS (rpms-rpc#521).
class AuthenticationHeldKeysRequiredRpcsTest < Minitest::Test
  def test_authentication_required_rpcs_lists_nphaskey_not_ciavcxus_haskeys
    json = JSON.parse(File.read(RpmsRpc::Compatibility::REQUIRED_PATH))
    auth = json.fetch("modules").fetch("RpmsRpc::Authentication")

    refute_includes auth, "CIAVCXUS HASKEYS",
                    "held_keys must not send CIAVCXUS HASKEYS"
    assert_includes auth, "ORWU NPHASKEY",
                    "held_keys must send ORWU NPHASKEY per key under OR CPRS GUI CHART"
  end
end
