# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/conformance/release_inventory"
require_relative "release_under_test"

# rpms-rpc#416: a MockClient held to a release's #19.05 (the committed fixture, cut from a real release; (<tag>-contexts_19_05.txt, openrpms#626)
# refuses an RPC its bound context does not serve, and a locked context, the way the server does.
class RpmsRpc::MockClientContextsTest < Minitest::Test
  SURFACE = ReleaseUnderTest.fixture.surface

  def mock(keys: [])
    RpmsRpc::MockClient.new.tap { |m| m.enforce_contexts!(SURFACE, keys: keys) }
  end

  def test_the_release_has_a_contexts_face
    assert SURFACE.contexts?, "#{SURFACE.tag}: no contexts_19_05.txt"
  end

  def test_an_rpc_the_bound_context_serves_is_answered
    m = mock
    m.with_context("OR CPRS GUI CHART") { assert_equal "", m.call_rpc("ORWPT SELECT", "1") }
  end

  def test_an_rpc_the_bound_context_does_not_serve_is_refused
    m = mock
    e = assert_raises(RpmsRpc::Client::RpcError) do
      m.with_context("OR CPRS GUI CHART") { m.call_rpc("BEHOVM2 VUNITS") }
    end
    assert_match(/OR CPRS GUI CHART does not serve BEHOVM2 VUNITS/, e.message)
    m.with_context("CIAV VUECENTRIC") { assert_equal "", m.call_rpc("BEHOVM2 VUNITS") }
  end

  def test_a_locked_context_is_refused_without_its_key
    e = assert_raises(RpmsRpc::Client::RpcError) { mock.create_context("ADEKRPC") }
    assert_match(/ADEKRPC is locked by ADEZMENU/, e.message)
    assert mock(keys: [ "ADEZMENU" ]).create_context("ADEKRPC")
  end

  # Sign-on is untouched: XUS SIGNON's RPCs and the broker-exempt ones run whatever is bound.
  def test_sign_on_rpcs_are_not_refused
    m = mock
    assert_equal "", m.call_rpc("XUS SIGNON SETUP")
    assert_equal "", m.call_rpc("XWB CREATE CONTEXT", "OR CPRS GUI CHART")
  end

  def test_an_unenforced_mock_refuses_nothing
    m = RpmsRpc::MockClient.new
    m.with_context("OR CPRS GUI CHART") { assert_equal "", m.call_rpc("BEHOVM2 VUNITS") }
  end
end
