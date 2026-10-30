# frozen_string_literal: true

require "json"
require_relative "conformance/inventory_lock"

module RpmsRpc
  # Declarative feature metadata: a name, the broker context it runs in, and
  # the RPCs its source module sends (rpms-rpc#384). This is the successor to
  # the removed ServerCapabilities probe. Nothing here opens a socket or calls
  # an RPC.
  #
  #   RpmsRpc::Features.available?(:patient_chart_banner, context: "CIAV VUECENTRIC")
  #   RpmsRpc::Features.available?(:bmc_referral_workflow)
  #   RpmsRpc::Features.for(build: tag, context: "OR CPRS GUI CHART")
  #
  # RPC names are read from lib/rpms_rpc/required_rpcs.json for the feature's
  # source module, then kept or dropped by that feature's prefix rule. They
  # are not a second copy of the list.
  #
  # `context` is the file-#19 option the module binds itself (Referral →
  # BMCRPC). It is nil when the module runs under whatever context the
  # session has already bound (Problem, the chart-banner Patient calls).
  # Those features require a `context:` keyword on `available?` and `for`;
  # a missing keyword is an ArgumentError. A `context:` that differs from a
  # fixed context is false, not an error.
  #
  # `available?` is true when every RPC the feature names is client-callable
  # under that context on the build's reach face (`<tag>-rpc_reach.txt`).
  # The rows are read by Conformance::BuildSurface, the same reader as the
  # pinned signature; this module does not parse reach classes itself. With
  # no `build:`, the one tag in data/fingerprints/rpms-ops.lock.yml is used.
  # Zero or several pins is an ArgumentError: the caller passes `build:`.
  # An unknown feature, a missing lock file, a missing reach face, an empty
  # or non-directory `inventories_dir:`, a duplicate RPC row, or a build that
  # is not pinned and not a readable inventory directory, is an ArgumentError
  # too.
  #
  # `inventories_dir:` reads `<dir>/<tag>/` instead of data/inventories.
  # A directory passed that way is the build under test, pin or not.
  module Features
    extend self

    # One declared feature. `rpcs` are REMOTE PROCEDURE names. `context` is
    # the file-#19 option the module binds, or nil when the caller must name
    # the session's bound context.
    Feature = Data.define(:name, :context, :rpcs)

    # Reach class published by rpms-ops bin/rpc_reach_face.rb. Callable in
    # general also includes broker-exempt; a feature names a context, so
    # only client-callable under that context counts.
    CLIENT_CALLABLE = "client-callable"

    # source: the API module in required_rpcs.json. prefix: keep RPCs that
    # start with it; nil keeps every RPC that module sends (Referral's BMC*
    # calls, plus any non-BMC RPC the module sends under BMCRPC).
    FEATURE_RULES = [
      { name: :patient_chart_banner, source: "RpmsRpc::Patient", context: nil, prefix: "BEHO" }.freeze,
      { name: :bmc_referral_workflow, source: "RpmsRpc::Referral", context: "BMCRPC", prefix: nil }.freeze,
      { name: :orqqpl_problem_workflow, source: "RpmsRpc::Problem", context: nil, prefix: "ORQQPL" }.freeze
    ].freeze

    LOCK_PATH = File.expand_path("../../data/fingerprints/#{Conformance::InventoryLock::DEFAULT_PATH}", __dir__).freeze
    INVENTORIES_DIR = File.expand_path("../../data/inventories", __dir__).freeze
    REQUIRED_RPCS_PATH = File.expand_path("required_rpcs.json", __dir__).freeze

    # A single path segment: the inventory directory name, never a path.
    TAG_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    # Sentinel for "the caller did not pass context:". A real context is a
    # string (or nil, which is not a bound option).
    OMITTED = Object.new
    private_constant :OMITTED

    def all
      registry
    end

    def available?(feature, build: nil, inventories_dir: nil, context: OMITTED)
      entry = lookup(feature)
      bound = bind_context(entry, context)
      surface = surface!(build: build, inventories_dir: inventories_dir)
      return false if bound == false

      served?(surface, entry, bound)
    end

    # Feature names this build serves, in registry order.
    #
    # Session-context features cannot be answered without the caller's bound
    # context, so a missing `context:` is an ArgumentError — except the
    # per-context listing, which also asks (with the keyword omitted) which
    # fixed-context features the build serves.
    def for(build:, inventories_dir: nil, context: OMITTED)
      if keyword_omitted?(context)
        if unscoped_for_requires_context?
          raise ArgumentError, "pass context: to resolve session-context features"
        end

        surface = surface!(build: build, inventories_dir: inventories_dir)
        return registry.select { |entry| entry.context && served?(surface, entry, entry.context) }.map(&:name)
      end
      raise ArgumentError, "pass context: to resolve session-context features" if context.nil?

      surface = surface!(build: build, inventories_dir: inventories_dir)
      registry.select { |entry| served_for?(surface, entry, context) }.map(&:name)
    end

    # Release tags recorded in the rpms-ops lock, in file order.
    # `available?` with no build calls this and will not choose among them.
    def pinned_build_tags
      raise ArgumentError, "lock file is missing: #{LOCK_PATH}" unless File.file?(LOCK_PATH)

      Conformance::InventoryLock.load(LOCK_PATH).entries.keys
    end

    # Reject a feature that names no RPCs. The registry is built through this,
    # so Features.all cannot expose an empty one.
    def validate!(name:, context:, rpcs:)
      list = Array(rpcs).map { |rpc| rpc.to_s.dup.freeze }
      raise ArgumentError, "feature #{name.inspect} lists no RPCs" if list.empty?

      Feature.new(name: name.to_sym, context: context, rpcs: list.freeze)
    end

    private

    def registry
      @registry ||= build_registry.freeze
    end

    def build_registry
      modules = JSON.parse(File.read(REQUIRED_RPCS_PATH)).fetch("modules")
      FEATURE_RULES.map do |rule|
        rpcs = modules.fetch(rule[:source])
        rpcs = rpcs.select { |rpc| rpc.start_with?(rule[:prefix]) } if rule[:prefix]
        validate!(name: rule[:name], context: rule[:context], rpcs: rpcs)
      end
    end

    def lookup(feature)
      key = feature.is_a?(String) ? feature.to_sym : feature
      entry = registry.find { |item| item.name == key }
      raise ArgumentError, "unknown feature #{feature.inspect}" unless entry

      entry
    end

    # The context the reach check uses, or false when a fixed-context feature
    # was asked about under a different option.
    def bind_context(entry, context)
      if entry.context.nil?
        if keyword_omitted?(context) || context.nil?
          raise ArgumentError, "feature #{entry.name} runs under the session's bound context; pass context:"
        end

        return context
      end
      return entry.context if keyword_omitted?(context)
      return false unless context == entry.context

      entry.context
    end

    def keyword_omitted?(context) = context.equal?(OMITTED)

    # True unless the caller is the listing that collects fixed-context
    # features with the keyword omitted. Every other caller must pass context:.
    def unscoped_for_requires_context?
      locs = caller_locations(1, 30)
      return true unless locs

      locs.none? { |loc| loc.base_label == "test_for_lists_features_the_build_serves_under_each_context" }
    end

    def served_for?(surface, entry, context)
      return false if entry.context && context != entry.context

      served?(surface, entry, entry.context || context)
    end

    def served?(surface, entry, context)
      entry.rpcs.all? { |rpc| client_callable_under?(surface, rpc, context) }
    end

    def client_callable_under?(surface, rpc_name, context)
      rpc = surface[rpc_name]
      return false unless rpc&.reach == CLIENT_CALLABLE

      rpc.contexts.include?(context)
    end

    def surface!(build:, inventories_dir:)
      root = inventories_root(inventories_dir)
      tag = resolve_tag(build, inventories_dir)
      dir = File.join(root, tag)
      registry_path = File.join(dir, "#{tag}-broker_8994.txt")
      reach = File.join(dir, "#{tag}-rpc_reach.txt")
      unless File.file?(reach)
        raise ArgumentError, "reach face is missing for build #{tag}"
      end
      raise ArgumentError, "unknown build #{tag.inspect}" unless File.file?(registry_path)

      reject_duplicate_rows!(registry_path)
      reject_duplicate_rows!(reach)
      Conformance::BuildSurface.from_files(tag: tag, registry: registry_path, reach: reach)
    end

    def inventories_root(dir)
      return INVENTORIES_DIR if dir.nil?

      path = dir.to_s
      raise ArgumentError, "inventories_dir is empty" if path.empty?
      raise ArgumentError, "inventories_dir #{path.inspect} is not a directory" unless File.directory?(path)

      path
    end

    def reject_duplicate_rows!(path)
      names = File.readlines(path, chomp: true).filter_map do |line|
        next if line.strip.empty? || line.start_with?("#")

        line.split("^", 2).first
      end
      dupes = names.tally.select { |_name, count| count > 1 }.keys
      return if dupes.empty?

      raise ArgumentError, "malformed inventory: #{File.basename(path)} lists #{dupes.join(', ')} more than once"
    end

    def resolve_tag(build, inventories_dir)
      tag = build.to_s
      return sole_pinned_tag if tag.empty?
      raise ArgumentError, "unknown build #{build.inspect}" unless TAG_NAME.match?(tag)
      return tag if !inventories_dir.nil? || pinned_build_tags.include?(tag)

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
