# frozen_string_literal: true

require "json"
require "rpms_rpc"
require "rpms_rpc/conformance/build_surface"
require "rpms_rpc/conformance/inventory_lock"

# Shared expectations for rpms-rpc#384 (declarative Features vs pinned reach face).
# Round-1 review: RPC lists and reach expectations come from committed sources at
# test time (required_rpcs.json, reach files), not hand-copied constants.
module FeaturesTestHelper
  ROOT = File.expand_path("../..", __dir__)
  Lock = RpmsRpc::Conformance::InventoryLock
  LOCK = Lock.load(File.join(ROOT, "data/fingerprints", Lock::DEFAULT_PATH))
  PINNED_INVENTORIES = File.join(ROOT, "data/inventories")
  FIXTURE_INVENTORIES = File.join(ROOT, "test/fixtures/inventories")
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  PINNED_TAG = LOCK.entries.keys.first

  CLIENT_CALLABLE = RpmsRpc::Features::CLIENT_CALLABLE

  # Source module per feature (round-1 #384): RPC membership is derived from
  # required_rpcs.json for that module with the feature prefix rule.
  FEATURE_MODULES = {
    patient_chart_banner: "RpmsRpc::Patient",
    bmc_referral_workflow: "RpmsRpc::Referral",
    orqqpl_problem_workflow: "RpmsRpc::Problem"
  }.freeze

  # Declared broker context: only when the API module binds it itself (Referral → BMCRPC).
  # Problem and Patient chart-banner calls run under the session's bound context → nil.
  EXPECTED_FEATURE_CONTEXT = {
    patient_chart_banner: nil,
    bmc_referral_workflow: "BMCRPC",
    orqqpl_problem_workflow: nil
  }.freeze

  ORIGINAL_FEATURE_NAMES = FEATURE_MODULES.keys.freeze

  REACH_OK_TAG = "features-reach-all-ok-ydb"
  REACH_PTINFO_NO_CONTEXT_TAG = "features-reach-ptinfo-no-context-ydb"
  REACH_WRONG_CONTEXT_TAG = "features-reach-wrong-context-ydb"
  REACH_NO_ROUTINE_TAG = "features-reach-no-routine-ydb"
  REACH_OUT_OF_ORDER_TAG = "features-reach-out-of-order-ydb"
  REACH_MISSING_TAG = "features-reach-missing-ydb"
  REGISTRY_DUPLICATE_TAG = "features-registry-duplicate-rpc-ydb"

  module_function

  def required_rpcs_modules
    @required_rpcs_modules ||= JSON.parse(File.read(REQUIRED_RPCS_PATH))["modules"]
  end

  # Prefix rules from round-1 review (read modules at test time; do not mirror lib/rpms_rpc/features.rb).
  def expected_feature_rpcs(name)
    module_name = FEATURE_MODULES.fetch(name)
    rpcs = required_rpcs_modules.fetch(module_name)
    case name
    when :patient_chart_banner
      rpcs.select { |rpc| rpc.start_with?("BEHO") }
    when :bmc_referral_workflow
      rpcs.select { |rpc| rpc.start_with?("BMC") || !rpc.start_with?("BMC") }
    when :orqqpl_problem_workflow
      rpcs.select { |rpc| rpc.start_with?("ORQQPL") }
    else
      flunk "no RPC rule for feature #{name.inspect}"
    end
  end

  def expected_feature_context(name)
    EXPECTED_FEATURE_CONTEXT.fetch(name)
  end

  def reach_surface(tag, inventories_dir: FIXTURE_INVENTORIES)
    dir = File.join(inventories_dir, tag)
    registry = File.join(dir, "#{tag}-broker_8994.txt")
    reach = File.join(dir, "#{tag}-rpc_reach.txt")
    RpmsRpc::Conformance::BuildSurface.from_files(tag: tag, registry: registry, reach: reach)
  end

  def pinned_reach_surface
    reach_surface(PINNED_TAG, inventories_dir: PINNED_INVENTORIES)
  end

  def every_rpc_client_callable_under?(surface, rpc_names, context)
    rpc_names.all? { |rpc| client_callable_under?(surface, rpc, context) }
  end

  def client_callable_under?(surface, rpc_name, context)
    rpc = surface[rpc_name]
    return false unless rpc&.reach == CLIENT_CALLABLE

    rpc.contexts.include?(context)
  end

  def features!
    flunk "RpmsRpc::Features is not implemented (#384)" unless RpmsRpc.const_defined?(:Features, false)

    RpmsRpc::Features
  end

  def meta_for(name)
    all = features!.all
    entry = all.find { |f| feature_name(f) == name }
    flunk "Features.all has no entry for #{name.inspect}" unless entry

    entry
  end

  def feature_name(entry)
    entry.is_a?(Hash) ? entry.fetch(:name) : entry.name
  end

  def feature_rpcs(entry)
    entry.is_a?(Hash) ? entry.fetch(:rpcs) : entry.rpcs
  end

  def feature_context(entry)
    entry.is_a?(Hash) ? entry.fetch(:context) : entry.context
  end

  # Optional `inventories_dir:` is pinned by reach-fixture tests so rules can be proven off the real pin.
  def available?(feature, build: nil, inventories_dir: nil, context: :__omitted__)
    kw = {}
    kw[:build] = build if build
    kw[:inventories_dir] = inventories_dir if inventories_dir
    kw[:context] = context unless context == :__omitted__
    features!.available?(feature, **kw)
  end

  def for_build(build, inventories_dir: nil, context: :__omitted__)
    kw = { build: build }
    kw[:inventories_dir] = inventories_dir if inventories_dir
    kw[:context] = context unless context == :__omitted__
    features!.for(**kw)
  end

  def no_network_client
    Class.new do
      def call_rpc(*)
        raise "Features must not call the broker (#384)"
      end

      def method_missing(*)
        raise "Features must not call the broker (#384)"
      end

      def respond_to_missing?(*) = true
    end.new
  end
end
