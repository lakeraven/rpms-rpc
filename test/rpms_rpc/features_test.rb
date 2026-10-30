# frozen_string_literal: true

require "minitest/autorun"
require "json"
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
      expected_ctx = expected_feature_context(name)
      if expected_ctx.nil?
        assert_nil feature_context(meta), name
      else
        assert_equal expected_ctx, feature_context(meta), name
      end
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

  def test_fixed_context_feature_available_ignores_caller_context
    # Round-2 #384: fixed-context features are judged under their declared context only;
    # a caller context: is ignored (replaces "mismatch → false").
    without = available?(:bmc_referral_workflow, build: PINNED_TAG)
    with_wrong = available?(:bmc_referral_workflow, build: PINNED_TAG, context: "CIAV VUECENTRIC")
    assert_equal without, with_wrong
    assert without
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

  def test_for_without_context_returns_fixed_context_features_served_on_build
    # Round-2 #384: no context: → fixed-context features only; session-context features omitted, never raise.
    expected = expected_for_feature_names(PINNED_TAG)
    assert_equal expected, for_build(PINNED_TAG)
    refute_includes for_build(PINNED_TAG), :patient_chart_banner
    refute_includes for_build(PINNED_TAG), :orqqpl_problem_workflow
  end

  def test_for_with_context_returns_fixed_and_session_features_served_under_that_context
    ciav = for_build(PINNED_TAG, context: "CIAV VUECENTRIC")
    assert_equal expected_for_feature_names(PINNED_TAG, context: "CIAV VUECENTRIC"), ciav
    assert_includes ciav, :patient_chart_banner if available?(:patient_chart_banner, build: PINNED_TAG, context: "CIAV VUECENTRIC")

    cprs = for_build(PINNED_TAG, context: "OR CPRS GUI CHART")
    assert_equal expected_for_feature_names(PINNED_TAG, context: "OR CPRS GUI CHART"), cprs
    assert_includes cprs, :orqqpl_problem_workflow if available?(:orqqpl_problem_workflow, build: PINNED_TAG, context: "OR CPRS GUI CHART")
  end

  def test_features_rb_does_not_use_caller_or_caller_locations
    source = File.read(File.join(ROOT, "lib/rpms_rpc/features.rb"))
    refute_match(/\bcaller_locations\s*\(/, source, "Features must not inspect the call stack (#384)")
    refute_match(/\bcaller\s*\(/, source, "Features must not inspect the call stack (#384)")
  end

  def test_required_rpcs_missing_file_raises_argument_error_naming_path
    missing = File.join(Dir.mktmpdir("features-rpcs-"), "no-required-rpcs.json")
    refute File.file?(missing)
    err = assert_raises(ArgumentError) { with_required_rpcs_path(missing) { features!.all } }
    assert_match(/required_rpcs/i, err.message)
    assert_match(File.basename(missing), err.message)
  end

  def test_required_rpcs_invalid_json_raises_argument_error_naming_path
    path = File.join(Dir.mktmpdir("features-rpcs-"), "bad.json")
    File.write(path, "{not json")
    err = assert_raises(ArgumentError) { with_required_rpcs_path(path) { features!.all } }
    assert_match(/required_rpcs/i, err.message)
    assert_match(File.basename(path), err.message)
    refute_instance_of JSON::ParserError, err
  end

  def test_required_rpcs_missing_module_raises_argument_error_naming_module
    path = File.join(Dir.mktmpdir("features-rpcs-"), "missing-module.json")
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    doc["modules"].delete("RpmsRpc::Referral")
    File.write(path, JSON.generate(doc))
    err = assert_raises(ArgumentError) { with_required_rpcs_path(path) { features!.all } }
    assert_match(/required_rpcs/i, err.message)
    assert_match(/RpmsRpc::Referral/, err.message)
  end

  def test_required_rpcs_module_not_nonempty_string_array_raises_argument_error
    path = File.join(Dir.mktmpdir("features-rpcs-"), "bad-module.json")
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    doc["modules"]["RpmsRpc::Problem"] = "ORQQPL LIST"
    File.write(path, JSON.generate(doc))
    err = assert_raises(ArgumentError) { with_required_rpcs_path(path) { features!.all } }
    assert_match(/required_rpcs/i, err.message)
    assert_match(/RpmsRpc::Problem/, err.message)

    doc["modules"]["RpmsRpc::Problem"] = []
    File.write(path, JSON.generate(doc))
    err = assert_raises(ArgumentError) { with_required_rpcs_path(path) { features!.all } }
    assert_match(/RpmsRpc::Problem/, err.message)

    doc["modules"]["RpmsRpc::Problem"] = [ "ORQQPL LIST", "" ]
    File.write(path, JSON.generate(doc))
    err = assert_raises(ArgumentError) { with_required_rpcs_path(path) { features!.all } }
    assert_match(/RpmsRpc::Problem/, err.message)
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

  def test_reach_fixture_no_entry_point_is_false
    refute available?(:patient_chart_banner,
                      build: REACH_NO_ENTRY_POINT_TAG,
                      inventories_dir: FIXTURE_INVENTORIES,
                      context: "CIAV VUECENTRIC")
  end

  def test_malformed_reach_rows_out_of_registry_order_raises_argument_error
    Dir.mktmpdir("features-reach-") do |tmpdir|
      tag = write_synthetic_inventory(
        tmpdir, "features-reach-order-ydb",
        reach_lines: CHART_BANNER_REACH_OK_LINES.rotate(1)
      )
      err = assert_raises(ArgumentError) do
        available?(:patient_chart_banner, build: tag, inventories_dir: tmpdir, context: "CIAV VUECENTRIC")
      end
      assert_match(/order/i, err.message)
      refute_match(/unknown build/i, err.message)
    end
  end

  def test_malformed_reach_empty_file_raises_argument_error
    Dir.mktmpdir("features-reach-") do |tmpdir|
      tag = write_synthetic_inventory(tmpdir, "features-reach-empty-ydb", reach_lines: [])
      err = assert_raises(ArgumentError) do
        available?(:patient_chart_banner, build: tag, inventories_dir: tmpdir, context: "CIAV VUECENTRIC")
      end
      assert_match(/reach/i, err.message)
    end
  end

  def test_malformed_reach_unknown_class_raises_argument_error
    reach = CHART_BANNER_REACH_OK_LINES.dup
    reach[0] = "BEHOPTCX PTINFO^maybe-callable^1^1^CIAV VUECENTRIC^"
    Dir.mktmpdir("features-reach-") do |tmpdir|
      tag = write_synthetic_inventory(tmpdir, "features-reach-bad-class-ydb", reach_lines: reach)
      err = assert_raises(ArgumentError) do
        available?(:patient_chart_banner, build: tag, inventories_dir: tmpdir, context: "CIAV VUECENTRIC")
      end
      assert_match(/reach/i, err.message)
      assert_match(/maybe-callable|not one of/i, err.message)
    end
  end

  def test_build_with_reach_but_no_registry_raises_argument_error
    Dir.mktmpdir("features-registry-") do |tmpdir|
      tag = write_reach_only_inventory(tmpdir, "features-no-registry-ydb", reach_lines: CHART_BANNER_REACH_OK_LINES)
      err = assert_raises(ArgumentError) do
        available?(:bmc_referral_workflow, build: tag, inventories_dir: tmpdir)
      end
      assert_match(/registry.*missing/i, err.message)
      refute_match(/unknown build/i, err.message)
    end
  end

  def test_repeated_available_and_for_share_one_build_surface_read
    feat = features!
    Dir.mktmpdir("features-cache-") do |tmpdir|
      copy_inventory_tag_to_tmpdir(tmpdir, PINNED_TAG)
      feat.reset!
      kw = { build: PINNED_TAG, inventories_dir: tmpdir }
      bmc = available?(:bmc_referral_workflow, **kw)
      chart = available?(:patient_chart_banner, **kw, context: "CIAV VUECENTRIC")
      listed = for_build(PINNED_TAG, inventories_dir: tmpdir)

      break_reach_face_on_disk(tmpdir, PINNED_TAG)

      assert_equal bmc, available?(:bmc_referral_workflow, **kw),
                   "cached build surface must answer after reach face changes on disk"
      assert_equal chart, available?(:patient_chart_banner, **kw, context: "CIAV VUECENTRIC"),
                   "cached build surface must answer after reach face changes on disk"
      assert_equal listed, for_build(PINNED_TAG, inventories_dir: tmpdir),
                   "cached build surface must answer after reach face changes on disk"
    end
  ensure
    feat.reset!
  end

  def test_reset_clears_cached_build_surface
    feat = features!
    Dir.mktmpdir("features-cache-") do |tmpdir|
      copy_inventory_tag_to_tmpdir(tmpdir, PINNED_TAG)
      feat.reset!
      kw = { build: PINNED_TAG, inventories_dir: tmpdir }
      assert available?(:bmc_referral_workflow, **kw)

      break_reach_face_on_disk(tmpdir, PINNED_TAG)

      assert available?(:bmc_referral_workflow, **kw),
             "second available? must reuse the cached build surface"

      feat.reset!

      err = assert_raises(ArgumentError) { available?(:bmc_referral_workflow, **kw) }
      assert_match(/reach/i, err.message)
    end
  ensure
    feat.reset!
  end
end
