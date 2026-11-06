# frozen_string_literal: true

require "minitest/autorun"
require_relative "features_test_helper"

# Every RPC named by committed feature metadata must appear on every pinned build signature (#384, ADR 0008).
class FeaturesConformanceTest < Minitest::Test
  include FeaturesTestHelper

  def pinned_surfaces
    @pinned_surfaces ||= LOCK.surfaces(inventories_dir: PINNED_INVENTORIES)
  end

  def test_every_feature_rpc_is_registered_on_every_pinned_build
    refute_empty pinned_surfaces, "no build pinned in #{LOCK.path}"
    problems = []
    pinned_surfaces.each do |tag, surface|
      features!.all.each do |meta|
        name = feature_name(meta)
        feature_rpcs(meta).each do |rpc|
          unless surface[rpc]
            problems << "#{tag}: feature #{name} names #{rpc.inspect}, which is not in the reach face"
          end
        end
      end
    end
    assert_empty problems, problems.join("\n  ")
  end
end
