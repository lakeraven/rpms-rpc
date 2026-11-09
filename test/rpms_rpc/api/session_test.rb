# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/session"
require_relative "../captured_replies"

# Session reads the CIAVCXUS VIMINFO replies a fresh rpms-ydb container sent
# (test/fixtures/captured_replies/ciavcxus-viminfo.yml), replayed through
# CiaClient. DUZ 206 is PROFILE,MD on the build.
class SessionTest < Minitest::Test
  VIMINFO = "CIAVCXUS VIMINFO"

  def teardown
    RpmsRpc.reset!
  end

  def replay(name = "profile_md")
    client = CapturedReplies::ReplayCiaClient.new(VIMINFO => [ CapturedReplies.raw("ciavcxus-viminfo", name) ])
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def test_bootstrap_returns_the_vim_info_of_the_user
    replay

    result = RpmsRpc::Session.bootstrap("206")

    assert_equal [ :vim_info ], result.keys
    assert_equal({ duz: 206, user_name: "PROFILE,MD", timeouts: "1800;1800;60", compose_mode: false, design_mode: false },
                 result[:vim_info].slice(:duz, :user_name, :timeouts, :compose_mode, :design_mode))
  end

  # "CIAVM DEFAULT SOURCE" is the VueCentric client's config root, the path
  # the Windows shell loads its component registry from. A frontend-agnostic
  # consumer has none, so the bootstrap neither asks for it nor returns it
  # (#239; ADR 0004 disqualifier 2). CIAVMCFG GETREG dumps VueCentric's
  # widget registry (^CIAVOBJ), which a web app has no use for (#522).
  # Bootstrap sends VIMINFO, with the DUZ, and nothing else.
  def test_bootstrap_sends_viminfo_with_the_duz_and_nothing_else
    client = replay

    result = RpmsRpc::Session.bootstrap("206")

    assert_equal [ { rpc: VIMINFO, params: [ "206" ] } ], client.calls
    refute result.key?(:config_root)
    refute result.key?(:registry)
    refute RpmsRpc::Session.const_defined?(:DEFAULT_SOURCE_PARAM)
  end

  def test_the_getpar_mapping_is_gone
    assert_raises(NoMethodError, KeyError, ArgumentError) { RpmsRpc::DataMapper[:session_default_source] }
  end

  def test_bootstrap_returns_nil_for_blank_duz_without_a_call
    client = CapturedReplies::ReplayCiaClient.new({})
    RpmsRpc.configure { |cfg| cfg.client = client }

    assert_nil RpmsRpc::Session.bootstrap(nil)
    assert_nil RpmsRpc::Session.bootstrap("")
    assert_nil RpmsRpc::Session.bootstrap("0")
    assert_empty client.calls
  end

  # VIMINFO answers an empty reply for a DUZ no user holds (#221).
  def test_bootstrap_of_an_unknown_duz_has_empty_vim_info
    replay("no_such_user")

    result = RpmsRpc::Session.bootstrap("9999")

    assert_equal({ vim_info: {} }, result)
  end
end
