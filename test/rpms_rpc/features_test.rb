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

  def test_all_registers_the_three_original_features_with_expected_context
    names = features!.all.map { |f| feature_name(f) }.sort
    assert_equal ORIGINAL_FEATURE_NAMES.sort, names

    ORIGINAL_FEATURE_NAMES.each do |name|
      meta = meta_for(name)
      assert_equal expected_feature_context(name), feature_context(meta), name
    end
  end

  def test_each_feature_rpcs_match_required_rpcs_json_for_its_module
    # Round-1 #384: feature RPCs are what the source module sends (from required_rpcs.json),
    # not a probe subset and not a hand copy of lib/rpms_rpc/features.rb constants.
    ORIGINAL_FEATURE_NAMES.each do |name|
      expected = expected_feature_rpcs(name)
      refute_empty expected, "#{name} must name at least one RPC"
      actual = feature_rpcs(meta_for(name)).map(&:to_s)
      assert_equal expected.sort, actual.sort, name
    end
  end

  def test_features_all_never_includes_empty_rpcs
    # Round-1 #384: empty rpcs is invalid; the registry must not expose one via Features.all.
    features!.all.each do |meta|
      refute_empty feature_rpcs(meta), feature_name(meta)
    end
  end

  def test_registry_rejects_empty_rpcs_at_validation
    # Round-1 #384: ArgumentError at definition / validation, not a silent empty feature.
    assert_raises(ArgumentError) do
      features!.validate!(name: :empty_feature, context: nil, rpcs: [])
    end
  end

  def test_session_bound_available_requires_context_keyword
    # Round-1 #384: Problem and chart-banner Patient calls need the caller's bound context.
    assert_raises(ArgumentError) { available?(:orqqpl_problem_workflow, build: PINNED_TAG) }
    assert_raises(ArgumentError) { available?(:patient_chart_banner, build: PINNED_TAG) }
  end

  def test_fixed_context_feature_ignores_wrong_context_keyword_with_false
    # Round-1 #384: Referral binds BMCRPC; a different context: → false, not an error.
    refute available?(:bmc_referral_workflow, build: PINNED_TAG, context: "CIAV VUECENTRIC")
  end

  def test_orqqpl_available_on_pinned_build_matches_reach_for_cprs_context
    rpcs = expected_feature_rpcs(:orqqpl_problem_workflow)
    surface = pinned_reach_surface
    expected = every_rpc_client_callable_under?(surface, rpcs, "OR CPRS GUI CHART")
    assert_equal expected,
                 available?(:orqqpl_problem_workflow, build: PINNED_TAG, context: "OR CPRS GUI CHART")
  end

  def test_orqqpl_available_on_pinned_build_matches_reach_for_ciav_context
    rpcs = expected_feature_rpcs(:orqqpl_problem_workflow)
    surface = pinned_reach_surface
    expected = every_rpc_client_callable_under?(surface, rpcs, "CIAV VUECENTRIC")
    assert_equal expected,
                 available?(:orqqpl_problem_workflow, build: PINNED_TAG, context: "CIAV VUECENTRIC")
  end

  def test_patient_chart_banner_available_on_pinned_build_matches_reach_for_ciav
    rpcs = expected_feature_rpcs(:patient_chart_banner)
    surface = pinned_reach_surface
    expected = every_rpc_client_callable_under?(surface, rpcs, "CIAV VUECENTRIC")
    assert_equal expected,
                 available?(:patient_chart_banner, build: PINNED_TAG, context: "CIAV VUECENTRIC")
  end

  def test_bmc_referral_workflow_available_on_pinned_build
    assert available?(:bmc_referral_workflow, build: PINNED_TAG)
  end

  def test_available_without_build_uses_the_sole_pinned_tag
    skip "need exactly one pinned tag to assert default build" unless LOCK.entries.size == 1

    assert available?(:patient_chart_banner, context: "CIAV VUECENTRIC")
    assert available?(:bmc_referral_workflow)
    assert available?(:orqqpl_problem_workflow, context: "OR CPRS GUI CHART")
  end

  def test_available_without_build_raises_when_more_than_one_tag_is_pinned
    feat = features!
    feat.stub :pinned_build_tags, %w[one-ydb two-ydb] do
      assert_raises(ArgumentError) { feat.available?(:patient_chart_banner, context: "CIAV VUECENTRIC") }
    end
  end

  def test_unknown_feature_raises_argument_error
    assert_raises(ArgumentError) { available?(:not_a_feature, build: PINNED_TAG) }
  end

  def test_unknown_build_raises_argument_error
    assert_raises(ArgumentError) { available?(:patient_chart_banner, build: "bcer-0.0-20990101-deadbee-ydb") }
  end

  def test_pinned_build_without_reach_face_raises_argument_error
    # Round-1 #384: missing reach for a build under test is not "unknown build".
    err = assert_raises(ArgumentError) do
      available?(:bmc_referral_workflow,
                 build: REACH_MISSING_TAG,
                 inventories_dir: FIXTURE_INVENTORIES)
    end
    assert_match(/reach face is missing/i, err.message)
    refute_match(/unknown build/i, err.message)
  end

  def test_missing_lock_file_raises_argument_error
    # Round-1 #384: a missing lock path must say the lock file is missing, not "pins 0 builds".
    missing = File.join(Dir.mktmpdir("features-lock-"), "no-rpms-ops.lock.yml")
    refute File.file?(missing)
    original = RpmsRpc::Features::LOCK_PATH
    RpmsRpc::Features.send(:remove_const, :LOCK_PATH)
    RpmsRpc::Features.const_set(:LOCK_PATH, missing)
    err = assert_raises(ArgumentError) { features!.available?(:bmc_referral_workflow) }
    assert_match(/lock file is missing/i, err.message)
    refute_match(/pins 0 builds/i, err.message)
  ensure
    RpmsRpc::Features.send(:remove_const, :LOCK_PATH)
    RpmsRpc::Features.const_set(:LOCK_PATH, original)
  end

  def test_empty_inventories_dir_raises_argument_error
    assert_raises(ArgumentError) do
      available?(:bmc_referral_workflow, build: PINNED_TAG, inventories_dir: "")
    end
  end

  def test_non_directory_inventories_dir_raises_argument_error
    path = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")
    assert_raises(ArgumentError) do
      available?(:bmc_referral_workflow, build: PINNED_TAG, inventories_dir: path)
    end
  end

  def test_duplicate_rpc_in_inventory_raises_malformed_argument_error
    # Round-1 #384: duplicate RPC names in registry/reach → ArgumentError (malformed inventory).
    err = assert_raises(ArgumentError) do
      available?(:bmc_referral_workflow,
                 build: REGISTRY_DUPLICATE_TAG,
                 inventories_dir: FIXTURE_INVENTORIES)
    end
    assert_match(/malformed inventory/i, err.message)
  end

  def test_available_never_touches_the_broker_client
    client = no_network_client
    RpmsRpc.stub :client, client do
      available?(:patient_chart_banner, build: PINNED_TAG, context: "CIAV VUECENTRIC")
      available?(:bmc_referral_workflow, build: PINNED_TAG)
      available?(:orqqpl_problem_workflow, build: PINNED_TAG, context: "OR CPRS GUI CHART")
    end
  end

  def test_for_lists_features_the_build_serves_under_each_context
    assert_includes for_build(PINNED_TAG, context: "CIAV VUECENTRIC"), :patient_chart_banner
    assert_includes for_build(PINNED_TAG), :bmc_referral_workflow
    assert_includes for_build(PINNED_TAG, context: "OR CPRS GUI CHART"), :orqqpl_problem_workflow
  end

  def test_for_requires_context_for_session_bound_features
    assert_raises(ArgumentError) { for_build(PINNED_TAG) }
  end

  def test_reach_fixture_all_client_callable_under_feature_context_is_true
    assert available?(:patient_chart_banner,
                      build: REACH_OK_TAG,
                      inventories_dir: FIXTURE_INVENTORIES,
                      context: "CIAV VUECENTRIC")
  end

  def test_reach_fixture_no_context_rpc_is_false
    refute available?(:patient_chart_banner,
                      build: REACH_PTINFO_NO_CONTEXT_TAG,
                      inventories_dir: FIXTURE_INVENTORIES,
                      context: "CIAV VUECENTRIC")
  end

  def test_reach_fixture_wrong_context_is_false
    refute available?(:patient_chart_banner,
                      build: REACH_WRONG_CONTEXT_TAG,
                      inventories_dir: FIXTURE_INVENTORIES,
                      context: "CIAV VUECENTRIC")
  end

  def test_reach_fixture_no_routine_is_false
    refute available?(:patient_chart_banner,
                      build: REACH_NO_ROUTINE_TAG,
                      inventories_dir: FIXTURE_INVENTORIES,
                      context: "CIAV VUECENTRIC")
  end

  def test_reach_fixture_out_of_order_is_false
    refute available?(:patient_chart_banner,
                      build: REACH_OUT_OF_ORDER_TAG,
                      inventories_dir: FIXTURE_INVENTORIES,
                      context: "CIAV VUECENTRIC")
  end
end
