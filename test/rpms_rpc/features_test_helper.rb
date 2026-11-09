# frozen_string_literal: true

require "fileutils"
require "json"
require "rpms_rpc"
require "rpms_rpc/conformance/build_surface"
require "rpms_rpc/conformance/inventory_lock"
require_relative "pinned_rpcs_test_helper"

# Shared expectations for rpms-rpc#384 (declarative Features vs pinned reach face).
# Round-1 review: RPC lists and reach expectations come from committed sources at
# test time (required_rpcs.json, rpcs.json documents), not hand-copied constants.
module FeaturesTestHelper
  ROOT = File.expand_path("../..", __dir__)
  Lock = RpmsRpc::Conformance::InventoryLock
  LOCK = Lock.load(File.join(ROOT, "data/fingerprints", Lock::DEFAULT_PATH))
  PINNED_INVENTORIES = File.join(ROOT, "data/inventories")
  FIXTURE_INVENTORIES = File.join(ROOT, "test/fixtures/inventories")
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  PINNED_TAG = LOCK.entries.keys.first

  CLIENT_CALLABLE = RpmsRpc::Features::CLIENT_CALLABLE

  # Source module per feature (round-1 #384): explicit RPC lists must stay a
  # subset of required_rpcs.json for that module (drift guard).
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

  # Explicit feature RPC lists (#384): must match Patient.brief_header, Problem ORQQPL*, Referral BMC*.
  PATIENT_CHART_BANNER_RPCS = [
    "BEHOPTCX PTINFO",
    "BEHOPTPC GETBDP",
    "ORWPT CWAD"
  ].freeze

  ORQQPL_PROBLEM_WORKFLOW_RPCS = [
    "ORQQPL AUDIT HIST",
    "ORQQPL CLIN SRCH",
    "ORQQPL DETAIL",
    "ORQQPL EDIT LOAD",
    "ORQQPL INIT PT",
    "ORQQPL LIST",
    "ORQQPL PROB COMMENTS",
    "ORQQPL PROBLEM LEX SEARCH",
    "ORQQPL PROVIDER LIST"
  ].freeze

  BMC_REFERRAL_WORKFLOW_RPCS = [
    "BMC ADD C32 PRINT LOG",
    "BMC ADD REFERRAL",
    "BMC CHK YEAR SITE PARAM",
    "BMC CONSULTATION STATUS UPDATE",
    "BMC GET PURPOSE OF REF API",
    "BMC GET RCIS TEMPLATE DETAIL",
    "BMC GET RCIS TEMPLATE LIST",
    "BMC GET REFERENCE DATA",
    "BMC GET REFERRAL",
    "BMC GET USERS/PROVIDERS",
    "BMC HEALTH SUMMARY TYPE",
    "BMC PATIENT ELIGIBILITY STATUS",
    "BMC PATIENT FACE SHEET",
    "BMC PATIENT HEALTH SUMMARY",
    "BMC PRINT REFERRAL",
    "BMC PROVIDERS",
    "BMC REFERRAL STATUS UPDATE",
    "BMC SEARCH REFERRAL",
    "BMC SEARCH REFERRED TO",
    "BMC UPDATE REFERRAL"
  ].freeze

  FEATURE_RPCS = {
    patient_chart_banner: PATIENT_CHART_BANNER_RPCS,
    bmc_referral_workflow: BMC_REFERRAL_WORKFLOW_RPCS,
    orqqpl_problem_workflow: ORQQPL_PROBLEM_WORKFLOW_RPCS
  }.freeze

  # Reverse drift guard (#384): module RPCs in required_rpcs.json must appear in the
  # feature list or here with a one-line reason (Referral: every call runs under BMCRPC).
  BMC_REFERRAL_WORKFLOW_MODULE_RPC_EXCLUSIONS = {}.freeze

  ORQQPL_PROBLEM_WORKFLOW_MODULE_RPC_EXCLUSIONS = {
    "BGOPROB SET" =>
      "IHS problem writes used by Problem.add/update/delete; outside the stock-VistA ORQQPL workflow the removed ServerCapabilities feature covered",
    "BGOPROB DEL" =>
      "IHS problem writes used by Problem.add/update/delete; outside the stock-VistA ORQQPL workflow the removed ServerCapabilities feature covered",
    "DDR GETS ENTRY DATA" =>
      "Problem.update/delete read the PROBLEM entry before writing and every write reads it back (#527)"
  }.freeze

  FEATURE_MODULE_RPC_EXCLUSIONS = {
    bmc_referral_workflow: BMC_REFERRAL_WORKFLOW_MODULE_RPC_EXCLUSIONS,
    orqqpl_problem_workflow: ORQQPL_PROBLEM_WORKFLOW_MODULE_RPC_EXCLUSIONS
  }.freeze

  REACH_OK_TAG = "features-reach-all-ok-ydb"
  REACH_PTINFO_NO_CONTEXT_TAG = "features-reach-ptinfo-no-context-ydb"
  REACH_WRONG_CONTEXT_TAG = "features-reach-wrong-context-ydb"
  REACH_NO_ROUTINE_TAG = "features-reach-no-routine-ydb"
  REACH_OUT_OF_ORDER_TAG = "features-reach-out-of-order-ydb"
  REACH_NO_ENTRY_POINT_TAG = "features-reach-no-entry-point-ydb"
  REACH_MISSING_TAG = "features-reach-missing-ydb"
  REGISTRY_DUPLICATE_TAG = "features-registry-duplicate-rpc-ydb"

  CHART_BANNER_RPCS = PATIENT_CHART_BANNER_RPCS

  # The chart-banner RPCs' records from the pinned rpcs.json, each client-callable under CIAV
  # VUECENTRIC; REACH (name => reach fields) changes one record's reach.
  def self.chart_banner_records(reach = {})
    CHART_BANNER_RPCS.map do |name|
      PinnedRpcsTestHelper.record(name, reach: { "class" => CLIENT_CALLABLE, "routine_present" => true, "tag_present" => true,
                                                 "contexts" => [ "CIAV VUECENTRIC" ], "exemptions" => [] }.merge(reach.fetch(name, {})))
    end
  end

  module_function

  def required_rpcs_modules
    @required_rpcs_modules ||= JSON.parse(File.read(REQUIRED_RPCS_PATH))["modules"]
  end

  def expected_feature_rpcs(name)
    FEATURE_RPCS.fetch(name)
  end

  def module_rpcs_for_feature(name)
    required_rpcs_modules.fetch(FEATURE_MODULES.fetch(name))
  end

  def module_rpc_exclusions_for_feature(name)
    FEATURE_MODULE_RPC_EXCLUSIONS.fetch(name)
  end

  # Every RPC the source module lists must be in the feature rpcs or documented exclusions.
  def assert_each_module_rpc_in_feature_or_exclusions!(name)
    module_name = FEATURE_MODULES.fetch(name)
    module_rpcs = module_rpcs_for_feature(name)
    feature_rpcs = expected_feature_rpcs(name).map(&:to_s)
    exclusions = module_rpc_exclusions_for_feature(name)

    module_rpcs.each do |rpc|
      next if feature_rpcs.include?(rpc)
      next if exclusions.key?(rpc)

      flunk "#{rpc.inspect} is listed for #{module_name} in required_rpcs.json but not in feature " \
            "#{name} rpcs; add it to the feature or to the exclusions"
    end

    exclusions.each_key do |rpc|
      assert_includes module_rpcs, rpc,
                      "#{rpc.inspect} is in exclusions for #{name} but not listed by #{module_name} " \
                      "in required_rpcs.json (stale exclusion)"
    end
  end

  # Write `<tmpdir>/<tag>/<tag>-rpcs.json` of RECORDS for Features under test (round-3 #384, #406).
  def write_synthetic_inventory(tmpdir, tag, records: FeaturesTestHelper.chart_banner_records, sort: true)
    PinnedRpcsTestHelper.write_inventory(tmpdir, tag, records, sort: sort)
    tag
  end

  # Copy a committed inventory tree into a temp root for cache tests (no minitest stubs).
  def copy_inventory_tag_to_tmpdir(tmpdir, tag, from_dir: PINNED_INVENTORIES)
    FileUtils.cp_r(File.join(from_dir, tag), File.join(tmpdir, tag))
    tag
  end

  def rpcs_json_path(tmpdir, tag)
    File.join(tmpdir, tag, "#{tag}-rpcs.json")
  end

  # After the build surface is cached, an uncached read would raise (rpcs.json missing).
  def break_rpcs_json_on_disk(tmpdir, tag)
    File.delete(rpcs_json_path(tmpdir, tag))
  end

  # Pinned test seam (round-2 #384): swap REQUIRED_RPCS_PATH, then Features.reset! reloads the registry.
  def with_required_rpcs_path(path)
    feat = features!
    original_path = RpmsRpc::Features::REQUIRED_RPCS_PATH
    RpmsRpc::Features.send(:remove_const, :REQUIRED_RPCS_PATH)
    RpmsRpc::Features.const_set(:REQUIRED_RPCS_PATH, path)
    feat.reset!
    yield
  ensure
    RpmsRpc::Features.send(:remove_const, :REQUIRED_RPCS_PATH)
    RpmsRpc::Features.const_set(:REQUIRED_RPCS_PATH, original_path)
    feat.reset!
  end

  def expected_for_feature_names(build, inventories_dir: PINNED_INVENTORIES, context: :__omitted__)
    surface =
      if build == PINNED_TAG && inventories_dir == PINNED_INVENTORIES
        pinned_reach_surface
      else
        reach_surface(build, inventories_dir: inventories_dir)
      end
    ORIGINAL_FEATURE_NAMES.select do |name|
      bound = expected_feature_context(name)
      if bound
        every_rpc_client_callable_under?(surface, expected_feature_rpcs(name), bound)
      elsif context == :__omitted__
        false
      else
        every_rpc_client_callable_under?(surface, expected_feature_rpcs(name), context)
      end
    end
  end

  def expected_feature_context(name)
    EXPECTED_FEATURE_CONTEXT.fetch(name)
  end

  def reach_surface(tag, inventories_dir: FIXTURE_INVENTORIES)
    RpmsRpc::Conformance::BuildSurface.load(File.join(inventories_dir, tag), tag)
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
