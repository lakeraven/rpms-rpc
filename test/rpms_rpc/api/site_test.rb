# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/site"
require_relative "../captured_replies"

# Site reads the BEHOSICX SITEINFO reply a fresh rpms-ydb container sent
# (test/fixtures/captured_replies/behosicx-siteinfo.yml), replayed through
# CiaClient.
class SiteTest < Minitest::Test
  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def site_reply = { "BEHOSICX SITEINFO" => [ CapturedReplies.raw("behosicx-siteinfo", "current") ] }

  def test_current_returns_the_authenticated_users_site
    client = replay(site_reply)

    site = RpmsRpc::Site.current("206")

    assert_equal({ domain: "DEMO.IHS.GOV", name: "DEMO IHS CLINIC", abbreviation: "8904", state: "ILLINOIS",
                   address: "123 ELM STREET", city: "ANYWHERE", zip: "99999", ien: 7819 },
                 site.slice(:domain, :name, :abbreviation, :state, :address, :city, :zip, :ien))
    assert_equal [ { rpc: "BEHOSICX SITEINFO", params: [] } ], client.calls, "SITEINFO takes no parameters"
  end

  def test_current_blank_duz_returns_nil_without_a_call
    client = replay({})

    assert_nil RpmsRpc::Site.current(nil)
    assert_nil RpmsRpc::Site.current("")
    assert_nil RpmsRpc::Site.current("0")
    assert_empty client.calls
  end

  def test_list_returns_current_as_single_element_array
    replay(site_reply)

    sites = RpmsRpc::Site.list("206")

    assert_equal 1, sites.length
    assert_equal 7819, sites.first[:ien]
  end

  def test_list_blank_duz_returns_empty
    client = replay({})

    assert_equal [], RpmsRpc::Site.list(nil)
    assert_equal [], RpmsRpc::Site.list("")
    assert_equal [], RpmsRpc::Site.list("0")
    assert_empty client.calls
  end
end
