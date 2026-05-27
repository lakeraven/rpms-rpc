# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/session"

class SessionTest < Minitest::Test
  CONFIG_ROOT = "c:\\CEHRTT15\\lib\\"

  def setup
    RpmsRpc.mock! do |m|
      m.seed_scalar(:session_default_source, "CIAVM DEFAULT SOURCE", CONFIG_ROOT)
      m.seed(:session_registry, "", { root: "HKLM\\Software\\IHS\\CIAVM" })
      m.seed(:session_vim_info, "301", {
        site_ien: 539,
        site_name: "TEST SERVICE UNIT",
        user_name: "PROVIDER,TEST"
      })
    end
  end

  def test_bootstrap_returns_documented_hash_shape
    result = RpmsRpc::Session.bootstrap("301")

    assert_equal CONFIG_ROOT, result[:config_root]
    assert_equal({ root: "HKLM\\Software\\IHS\\CIAVM" }, result[:registry])
    assert_equal "TEST SERVICE UNIT", result[:vim_info][:site_name]
    assert_equal 539, result[:default_site_ien]
  end

  def test_bootstrap_issues_all_three_rpcs
    RpmsRpc::Session.bootstrap("301")

    rpcs = RpmsRpc.client.received_calls.map { |c| c[:rpc] }
    assert_includes rpcs, "CIAVMRPC GETPAR"
    assert_includes rpcs, "CIAVMCFG GETREG"
    assert_includes rpcs, "CIAVCXUS VIMINFO"
  end

  def test_bootstrap_passes_default_source_param_to_getpar
    RpmsRpc::Session.bootstrap("301")

    getpar = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "CIAVMRPC GETPAR" }
    assert_equal [ "CIAVM DEFAULT SOURCE" ], getpar[:params]
  end

  def test_bootstrap_passes_duz_to_viminfo
    RpmsRpc::Session.bootstrap("301")

    vim = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "CIAVCXUS VIMINFO" }
    assert_equal [ "301" ], vim[:params]
  end

  def test_bootstrap_returns_nil_for_blank_duz
    assert_nil RpmsRpc::Session.bootstrap(nil)
    assert_nil RpmsRpc::Session.bootstrap("")
    assert_nil RpmsRpc::Session.bootstrap("0")
  end

  def test_bootstrap_handles_missing_vim_info_gracefully
    RpmsRpc.mock! do |m|
      m.seed_scalar(:session_default_source, "CIAVM DEFAULT SOURCE", CONFIG_ROOT)
      m.seed(:session_registry, "", { root: "HKLM" })
    end

    result = RpmsRpc::Session.bootstrap("9999")

    assert_equal CONFIG_ROOT, result[:config_root]
    assert_nil result[:default_site_ien]
    assert_equal({}, result[:vim_info])
  end
end
