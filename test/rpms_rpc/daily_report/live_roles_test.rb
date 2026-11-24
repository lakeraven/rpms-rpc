# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/daily_report"
require_relative "../../live/live_env"

# rpms-rpc#815: the daily report runs the live suite once per test role a live
# spec runs as. The gem does not load test/live, so it keeps its own list;
# this fails when a role is added to, or dropped from, either one.
class RpmsRpc::DailyReport::LiveRolesTest < Minitest::Test
  def test_the_report_runs_every_role_a_live_spec_runs_as_in_the_same_order
    assert_equal LiveSpec.roles_in_use.map(&:to_s), RpmsRpc::DailyReport::LIVE_ROLES
  end

  def test_every_live_role_has_a_suite_id_and_its_sign_on_keys_are_secret
    report = RpmsRpc::DailyReport
    assert_equal report::LIVE_ROLES, report::LIVE_SUITE_IDS.keys
    assert_equal report::LIVE_SUITE_IDS.values.uniq, report::LIVE_SUITE_IDS.values
    report::LIVE_ROLES.each do |role|
      assert_includes report::SIGN_ON_KEYS, "#{role.upcase}_ACCESS"
      assert_includes report::SIGN_ON_KEYS, "#{role.upcase}_VERIFY"
      assert_includes report::SIGN_ON_KEYS, "#{role.upcase}_ESIG"
    end
  end
end
