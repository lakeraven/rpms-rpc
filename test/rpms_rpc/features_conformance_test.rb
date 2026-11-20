# frozen_string_literal: true

require "minitest/autorun"
require_relative "features_test_helper"

# Every RPC named by committed feature metadata must appear on the openrpms release under test
# (#384, #724, ADR 0008): the latest published -ydb release, or OPENRPMS_RELEASE=<tag>.
class FeaturesConformanceTest < Minitest::Test
  include FeaturesTestHelper

  def test_every_feature_rpc_is_registered_on_the_release_under_test
    inv = ReleaseUnderTest.inventory(self)
    problems = features!.all.flat_map do |meta|
      feature_rpcs(meta).reject { |rpc| inv.surface[rpc] }.map do |rpc|
        "#{inv.tag}: feature #{feature_name(meta)} names #{rpc.inspect}, which is not in the reach face"
      end
    end
    assert_empty problems, problems.join("\n  ")
  end
end
