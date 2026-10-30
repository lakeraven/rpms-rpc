# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require_relative "features_test_helper"

# Declarative feature metadata resolved against the pinned build reach face (rpms-rpc#384).
# Replaces ServerCapabilities runtime probes (#370): no broker traffic, only committed inventories.
class FeaturesTest < Minitest::Test
  include FeaturesTestHelper

  def test_module_exists
    features!
  end

  def test_all_registers_the_three_original_features_with_rpcs_and_context
    names = features!.all.map { |f| feature_name(f) }.sort
    assert_equal ORIGINAL_FEATURES.keys.sort, names

    ORIGINAL_FEATURES.each do |name, expected|
      meta = meta_for(name)
      assert_equal expected[:context], feature_context(meta), name
      assert_equal expected[:rpcs].sort, feature_rpcs(meta).map(&:to_s).sort, name
    end
  end

  def test_bmc_referral_workflow_lists_every_bmc_rpc_referral_sends
    assert_equal BMC_REFERRAL_WORKFLOW_RPCS.sort, feature_rpcs(meta_for(:bmc_referral_workflow)).map(&:to_s).sort
  end

  def test_available_is_true_on_the_pinned_build_for_each_original_feature
    ORIGINAL_FEATURES.each_key do |feature|
      assert available?(feature, build: PINNED_TAG),
             "expected #{feature} on #{PINNED_TAG}"
    end
  end

  def test_available_without_build_uses_the_sole_pinned_tag
    skip "need exactly one pinned tag to assert default build" unless LOCK.entries.size == 1

    assert available?(:patient_chart_banner)
    assert available?(:bmc_referral_workflow)
    assert available?(:orqqpl_problem_workflow)
  end

  def test_available_without_build_raises_when_more_than_one_tag_is_pinned
    feat = features!
    feat.stub :pinned_build_tags, %w[one-ydb two-ydb] do
      assert_raises(ArgumentError) { feat.available?(:patient_chart_banner) }
    end
  end

  def test_unknown_feature_raises_argument_error
    assert_raises(ArgumentError) { available?(:not_a_feature, build: PINNED_TAG) }
  end

  def test_unknown_build_raises_argument_error
    assert_raises(ArgumentError) { available?(:patient_chart_banner, build: "bcer-0.0-20990101-deadbee-ydb") }
  end

  def test_available_never_touches_the_broker_client
    client = no_network_client
    RpmsRpc.stub :client, client do
      ORIGINAL_FEATURES.each_key do |feature|
        available?(feature, build: PINNED_TAG)
      end
    end
  end

  def test_for_lists_features_the_build_serves
    served = for_build(PINNED_TAG).sort
    assert_equal ORIGINAL_FEATURES.keys.sort, served
  end

  def test_reach_fixture_all_client_callable_under_feature_context_is_true
    assert available?(:patient_chart_banner,
                      build: REACH_OK_TAG,
                      inventories_dir: FIXTURE_INVENTORIES)
  end

  def test_reach_fixture_no_context_rpc_is_false
    refute available?(:patient_chart_banner,
                      build: REACH_PTINFO_NO_CONTEXT_TAG,
                      inventories_dir: FIXTURE_INVENTORIES)
  end

  def test_reach_fixture_wrong_context_is_false
    refute available?(:patient_chart_banner,
                      build: REACH_WRONG_CONTEXT_TAG,
                      inventories_dir: FIXTURE_INVENTORIES)
  end

  def test_reach_fixture_no_routine_is_false
    refute available?(:patient_chart_banner,
                      build: REACH_NO_ROUTINE_TAG,
                      inventories_dir: FIXTURE_INVENTORIES)
  end

  def test_reach_fixture_out_of_order_is_false
    refute available?(:patient_chart_banner,
                      build: REACH_OUT_OF_ORDER_TAG,
                      inventories_dir: FIXTURE_INVENTORIES)
  end
end
