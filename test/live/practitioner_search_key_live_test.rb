# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/practitioner"

# Practitioner.search(name, key: "PROVIDER") lists only users holding the
# PROVIDER key, as VueCentric's provider selection does (ORWU NEWPERS with its
# KEY parameter). On the demo build PROFILE,MD holds PROVIDER and
# PROFILE,SCHED does not (rpms-ops SEEDPERS). It reads only.
class PractitionerSearchKeyLiveTest < LiveSpec::Test
  def test_a_provider_search_lists_providers_and_not_other_users
    everyone = RpmsRpc::Practitioner.search("PROFILE").map { |r| r[:name].to_s.upcase }
    providers = RpmsRpc::Practitioner.search("PROFILE", key: "PROVIDER").map { |r| r[:name].to_s.upcase }

    assert_includes everyone, "PROFILE,SCHED", "the build has no PROFILE,SCHED: seed the demo personas"
    assert_includes providers, "PROFILE,MD"
    refute_includes providers, "PROFILE,SCHED"
    assert_empty providers - everyone, "a key narrows the list, never adds to it"
  end
end
