# frozen_string_literal: true

require_relative "conformance/inventory_lock"

module RpmsRpc
  # Declarative feature metadata: a name, the broker context it runs in, and
  # the RPCs it sends (rpms-rpc#384). This is the successor to the removed
  # ServerCapabilities probe. Nothing here opens a socket or calls an RPC.
  #
  #   RpmsRpc::Features.available?(:patient_chart_banner)
  #   RpmsRpc::Features.for(build: tag)
  #
  # `available?` is true when every RPC the feature names is client-callable
  # under that context on the build's reach face (`<tag>-rpc_reach.txt`).
  # The rows are read by Conformance::BuildSurface, the same reader as the
  # pinned signature; this module does not parse them itself. With no
  # `build:`, the one tag in data/fingerprints/rpms-ops.lock.yml is used.
  # Zero or several pins is an ArgumentError: the caller passes `build:`.
  # An unknown feature, or a build that is not pinned and not a readable
  # inventory directory, is an ArgumentError too.
  #
  # `inventories_dir:` reads `<dir>/<tag>/` instead of data/inventories.
  # A directory passed that way is the build under test, pin or not.
  module Features
    extend self

    # One declared feature. `rpcs` are REMOTE PROCEDURE names; `context` is
    # the file-#19 option those calls run under.
    Feature = Data.define(:name, :context, :rpcs)

    # Reach class published by rpms-ops bin/rpc_reach_face.rb. Callable in
    # general also includes broker-exempt; a feature names a context, so
    # only client-callable under that context counts.
    CLIENT_CALLABLE = "client-callable"

    PATIENT_CHART_BANNER_RPCS = [
      "BEHOPTCX PTINFO",
      "BEHOPTPC GETBDP",
      "BEHOCACV CWAD"
    ].freeze

    ORQQPL_PROBLEM_WORKFLOW_RPCS = [
      "ORQQPL INIT PT"
    ].freeze

    # The BMC* calls Referral sends. Each is registered under BMCRPC.
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

    REGISTRY = [
      Feature.new(name: :patient_chart_banner, context: "CIAV VUECENTRIC", rpcs: PATIENT_CHART_BANNER_RPCS),
      Feature.new(name: :bmc_referral_workflow, context: "BMCRPC", rpcs: BMC_REFERRAL_WORKFLOW_RPCS),
      Feature.new(name: :orqqpl_problem_workflow, context: "OR CPRS GUI CHART", rpcs: ORQQPL_PROBLEM_WORKFLOW_RPCS)
    ].freeze

    LOCK_PATH = File.expand_path("../../data/fingerprints/#{Conformance::InventoryLock::DEFAULT_PATH}", __dir__).freeze
    INVENTORIES_DIR = File.expand_path("../../data/inventories", __dir__).freeze

    # A single path segment: the inventory directory name, never a path.
    TAG_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    def all
      REGISTRY
    end

    def available?(feature, build: nil, inventories_dir: nil)
      entry = lookup(feature)
      served?(surface!(build: build, inventories_dir: inventories_dir), entry)
    end

    # Feature names this build serves, in registry order.
    def for(build:, inventories_dir: nil)
      surface = surface!(build: build, inventories_dir: inventories_dir)
      REGISTRY.select { |entry| served?(surface, entry) }.map(&:name)
    end

    # Release tags recorded in the rpms-ops lock, in file order.
    # `available?` with no build calls this and will not choose among them.
    def pinned_build_tags
      Conformance::InventoryLock.load(LOCK_PATH).entries.keys
    end

    private

    def lookup(feature)
      key = feature.is_a?(String) ? feature.to_sym : feature
      entry = REGISTRY.find { |item| item.name == key }
      raise ArgumentError, "unknown feature #{feature.inspect}" unless entry

      entry
    end

    def served?(surface, entry)
      entry.rpcs.all? { |rpc| client_callable_under?(surface, rpc, entry.context) }
    end

    def client_callable_under?(surface, rpc_name, context)
      rpc = surface[rpc_name]
      return false unless rpc&.reach == CLIENT_CALLABLE

      rpc.contexts.include?(context)
    end

    def surface!(build:, inventories_dir:)
      tag = resolve_tag(build, inventories_dir)
      dir = File.join(inventories_dir || INVENTORIES_DIR, tag)
      registry = File.join(dir, "#{tag}-broker_8994.txt")
      reach = File.join(dir, "#{tag}-rpc_reach.txt")
      unless File.file?(registry) && File.file?(reach)
        raise ArgumentError, "unknown build #{tag.inspect}"
      end

      Conformance::BuildSurface.from_files(tag: tag, registry: registry, reach: reach)
    end

    def resolve_tag(build, inventories_dir)
      tag = build.to_s
      return sole_pinned_tag if tag.empty?
      raise ArgumentError, "unknown build #{build.inspect}" unless TAG_NAME.match?(tag)
      return tag if inventories_dir || pinned_build_tags.include?(tag)

      raise ArgumentError, "unknown build #{build.inspect}"
    end

    def sole_pinned_tag
      tags = pinned_build_tags
      return tags.first if tags.one?

      detail = tags.empty? ? "none" : tags.join(", ")
      raise ArgumentError, "#{LOCK_PATH} pins #{tags.size} builds (#{detail}); pass build:"
    end
  end
end
