# frozen_string_literal: true

require "rpms_rpc/conformance/inventory_lock"

# Shared expectations for rpms-rpc#384 (declarative Features vs pinned reach face).
module FeaturesTestHelper
  ROOT = File.expand_path("../..", __dir__)
  Lock = RpmsRpc::Conformance::InventoryLock
  LOCK = Lock.load(File.join(ROOT, "data/fingerprints", Lock::DEFAULT_PATH))
  PINNED_INVENTORIES = File.join(ROOT, "data/inventories")
  FIXTURE_INVENTORIES = File.join(ROOT, "test/fixtures/inventories")

  PINNED_TAG = LOCK.entries.keys.first

  PATIENT_CHART_BANNER_RPCS = [
    "BEHOPTCX PTINFO",
    "BEHOPTPC GETBDP",
    "BEHOCACV CWAD"
  ].freeze

  ORQQPL_PROBLEM_WORKFLOW_RPCS = [
    "ORQQPL INIT PT"
  ].freeze

  # The 20 BMC* RPC names RpmsRpc::Referral sends (ApiCoverage); each is client-callable under BMCRPC on the pin.
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

  ORIGINAL_FEATURES = {
    patient_chart_banner: {
      context: "CIAV VUECENTRIC",
      rpcs: PATIENT_CHART_BANNER_RPCS
    },
    bmc_referral_workflow: {
      context: "BMCRPC",
      rpcs: BMC_REFERRAL_WORKFLOW_RPCS
    },
    orqqpl_problem_workflow: {
      context: "OR CPRS GUI CHART",
      rpcs: ORQQPL_PROBLEM_WORKFLOW_RPCS
    }
  }.freeze

  REACH_OK_TAG = "features-reach-all-ok-ydb"
  REACH_PTINFO_NO_CONTEXT_TAG = "features-reach-ptinfo-no-context-ydb"
  REACH_WRONG_CONTEXT_TAG = "features-reach-wrong-context-ydb"
  REACH_NO_ROUTINE_TAG = "features-reach-no-routine-ydb"
  REACH_OUT_OF_ORDER_TAG = "features-reach-out-of-order-ydb"

  module_function

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
  def available?(feature, build: nil, inventories_dir: nil)
    kw = {}
    kw[:build] = build if build
    kw[:inventories_dir] = inventories_dir if inventories_dir
    features!.available?(feature, **kw)
  end

  def for_build(build, inventories_dir: nil)
    kw = { build: build }
    kw[:inventories_dir] = inventories_dir if inventories_dir
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
