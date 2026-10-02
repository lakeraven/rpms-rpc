# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/session"

class SessionTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
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

    assert_equal({ root: "HKLM\\Software\\IHS\\CIAVM" }, result[:registry])
    assert_equal "TEST SERVICE UNIT", result[:vim_info][:site_name]
    assert_equal 539, result[:default_site_ien]
  end

  # "CIAVM DEFAULT SOURCE" is the VueCentric client's config root — the path
  # the Windows shell loads its component registry from. A frontend-agnostic
  # consumer has none, so the bootstrap neither asks for it nor returns it
  # (#239; ADR 0004 disqualifier 2).
  def test_bootstrap_does_not_read_the_vuecentric_config_root
    result = RpmsRpc::Session.bootstrap("301")

    refute result.key?(:config_root)
    refute_includes RpmsRpc.client.received_calls.map { |c| c[:rpc] }, "CIAVMRPC GETPAR"
    refute RpmsRpc::Session.const_defined?(:DEFAULT_SOURCE_PARAM)
  end

  def test_the_getpar_mapping_is_gone
    assert_raises(NoMethodError, KeyError, ArgumentError) { RpmsRpc::DataMapper[:session_default_source] }
  end

  def test_bootstrap_issues_the_registry_and_vim_info_rpcs
    RpmsRpc::Session.bootstrap("301")

    rpcs = RpmsRpc.client.received_calls.map { |c| c[:rpc] }
    assert_includes rpcs, "CIAVMCFG GETREG"
    assert_includes rpcs, "CIAVCXUS VIMINFO"
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
      m.seed(:session_registry, "", { root: "HKLM" })
    end

    result = RpmsRpc::Session.bootstrap("9999")

    assert_equal({ root: "HKLM" }, result[:registry])
    assert_nil result[:default_site_ien]
    assert_equal({}, result[:vim_info])
  end
end
