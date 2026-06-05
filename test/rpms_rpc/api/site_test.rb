# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/site"

class SiteTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      # BEHOSICX SITEINFO is line-based and takes no params; mock seeds the
      # response under the empty key to mirror the dispatch behavior.
      m.seed_lines(:site_info, "", {
        domain: "RPMS.MEDSPHERE.COM",
        name: "DEMO IHS CLINIC",
        abbreviation: "8904",
        state: "ILLINOIS",
        address: "123 ELM STREET",
        city: "ANYWHERE",
        zip: "99999",
        ien: 7819
      })
    end
  end

  def test_current_returns_the_authenticated_users_site
    site = RpmsRpc::Site.current("301")
    assert_equal 7819, site[:ien]
    assert_equal "DEMO IHS CLINIC", site[:name]
    assert_equal "8904", site[:abbreviation]
    assert_equal "RPMS.MEDSPHERE.COM", site[:domain]
  end

  def test_current_blank_duz_returns_nil
    assert_nil RpmsRpc::Site.current(nil)
    assert_nil RpmsRpc::Site.current("")
    assert_nil RpmsRpc::Site.current("0")
  end

  def test_list_returns_current_as_single_element_array
    sites = RpmsRpc::Site.list("301")
    assert_equal 1, sites.length
    assert_equal 7819, sites.first[:ien]
  end

  def test_list_blank_duz_returns_empty
    assert_equal [], RpmsRpc::Site.list(nil)
    assert_equal [], RpmsRpc::Site.list("")
    assert_equal [], RpmsRpc::Site.list("0")
  end
end
