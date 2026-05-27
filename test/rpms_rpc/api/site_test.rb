# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/site"

class SiteTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      # BEHOSICX SITEINFO keyed by user DUZ: returns the divisions the user
      # can access, with the currently-selected division flagged.
      m.seed_keyed_collection(:site_info, "301", [
        { ien: 539, name: "Yakama Service Unit", abbreviation: "YSU", current: true },
        { ien: 540, name: "Toppenish Clinic", abbreviation: "TOP", current: false },
        { ien: 541, name: "White Swan Clinic", abbreviation: "WS", current: false }
      ])

      m.seed_keyed_collection(:site_info, "999", [
        { ien: 539, name: "Yakama Service Unit", abbreviation: "YSU", current: false }
      ])
    end
  end

  def test_list_returns_divisions_user_can_access
    sites = RpmsRpc::Site.list("301")
    assert_equal 3, sites.length
    assert_equal [ 539, 540, 541 ], sites.map { |s| s[:ien] }
  end

  def test_list_blank_duz_returns_empty
    assert_equal [], RpmsRpc::Site.list(nil)
    assert_equal [], RpmsRpc::Site.list("")
    assert_equal [], RpmsRpc::Site.list("0")
  end

  def test_current_returns_the_flagged_division
    current = RpmsRpc::Site.current("301")
    assert_equal 539, current[:ien]
    assert_equal "Yakama Service Unit", current[:name]
  end

  def test_current_returns_nil_when_nothing_is_flagged
    assert_nil RpmsRpc::Site.current("999")
  end

  def test_current_blank_duz_returns_nil
    assert_nil RpmsRpc::Site.current(nil)
    assert_nil RpmsRpc::Site.current("")
  end

  def test_select_dispatches_to_the_site_info_rpc_with_duz_and_site_ien
    RpmsRpc::Site.select("301", 540)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BEHOSICX SITEINFO" && c[:params].length == 2 }
    refute_nil call, "expected BEHOSICX SITEINFO to be called with [duz, site_ien]"
    assert_equal [ "301", "540" ], call[:params]
  end

  def test_select_returns_false_for_invalid_args
    refute RpmsRpc::Site.select(nil, 540)
    refute RpmsRpc::Site.select("301", nil)
    refute RpmsRpc::Site.select("301", 0)
  end
end
