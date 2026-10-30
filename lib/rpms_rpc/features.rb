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
  # A fixed-context feature is judged under that declared context in both
  # `available?` and `for`; any `context:` passed with the call is ignored.
  # A session-context feature requires `context:` on `available?`. Omitting
  # the keyword, or passing nil, is an ArgumentError.
  #
  # `for(build:)` returns the fixed-context features the build serves.
  # `for(build:, context:)` returns those plus the session-context features
  # served under that context.
  #
  # `available?` is true when every RPC the feature names is client-callable
  # under that context on the build's reach face (`<tag>-rpc_reach.txt`).
  # The rows are read by Conformance::BuildSurface, the same reader as the
  # pinned signature; this module does not parse reach classes itself. With
  # no `build:`, the one tag in data/fingerprints/rpms-ops.lock.yml is used.
  # Zero or several pins is an ArgumentError: the caller passes `build:`.
  # An unknown feature, a missing lock file, a missing reach face, a missing
  # `<tag>-broker_8994.txt` registry, an empty or non-directory
  # `inventories_dir:`, a duplicate RPC row, a malformed reach face, or a
  # build that is not pinned and not a readable inventory directory, is an
  # ArgumentError too. `Conformance::BuildSurface::Error` from that reader is
  # re-raised as ArgumentError with the reader's reason kept.
  #
  # The parsed build surface is cached per resolved inventory directory, and
  # the parsed rpms-ops lock is cached with it, so a repeated `available?` or
  # `for` does not read those files again. `reset!` drops both. One mutex
  # guards the caches for concurrent readers.
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

    # One lock for the feature registry, the per-directory build surfaces, and
    # the parsed rpms-ops lock. Enough for concurrent readers; writers are reset!.
    CACHE_MUTEX = Mutex.new
    private_constant :CACHE_MUTEX

    def all
      registry
    end

    # Drop the cached feature registry, parsed build surfaces, and rpms-ops lock
    # so the next read loads REQUIRED_RPCS_PATH and the inventory files again.
    def reset!
      CACHE_MUTEX.synchronize do
        @registry = nil
        @surfaces = nil
        @pinned_lock = nil
        @pinned_lock_path = nil
      end
    end

    def available?(feature, build: nil, inventories_dir: nil, context: OMITTED)
      entry = lookup(feature)
      bound = bind_context(entry, context)
      surface = surface!(build: build, inventories_dir: inventories_dir)
      served?(surface, entry, bound)
    end

    # Feature names this build serves, in registry order.
    #
    # No `context:` lists the fixed-context features served under their own
    # context. `context:` adds the session-context features served under that
    # option. A fixed-context feature never consults the passed context.
    def for(build:, inventories_dir: nil, context: OMITTED)
      surface = surface!(build: build, inventories_dir: inventories_dir)
      registry.select { |entry| served_for?(surface, entry, context) }.map(&:name)
    end

    # Release tags recorded in the rpms-ops lock, in file order.
    # `available?` with no build calls this and will not choose among them.
    def pinned_build_tags
      pinned_lock.entries.keys
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
      CACHE_MUTEX.synchronize { @registry ||= build_registry.freeze }
    end

    def build_registry
      modules = required_modules
      FEATURE_RULES.map do |rule|
        rpcs = module_rpcs(modules, rule[:source])
        rpcs = rpcs.select { |rpc| rpc.start_with?(rule[:prefix]) } if rule[:prefix]
        validate!(name: rule[:name], context: rule[:context], rpcs: rpcs)
      end
    end

    def required_modules
      path = REQUIRED_RPCS_PATH
      doc = parse_required_rpcs(path)
      modules = doc["modules"] if doc.is_a?(Hash)
      return modules if modules.is_a?(Hash)

      raise ArgumentError, "required_rpcs file #{path} is missing module key \"modules\""
    end

    def parse_required_rpcs(path)
      raise ArgumentError, "required_rpcs file is missing: #{path}" unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      raise ArgumentError, "required_rpcs file is not valid JSON: #{path}"
    end

    # The module value itself, before the feature prefix rule. A missing key,
    # or a value that is not a non-empty array of non-empty strings, names
    # this file and that module.
    def module_rpcs(modules, module_name)
      unless modules.key?(module_name)
        raise ArgumentError, "required_rpcs file #{REQUIRED_RPCS_PATH} is missing module #{module_name}"
      end

      rpcs = modules[module_name]
      return rpcs if non_empty_string_array?(rpcs)

      raise ArgumentError, "required_rpcs file #{REQUIRED_RPCS_PATH} module #{module_name} must be a non-empty array of non-empty strings"
    end

    def non_empty_string_array?(value)
      value.is_a?(Array) && !value.empty? && value.all? { |item| item.is_a?(String) && !item.empty? }
    end

    def lookup(feature)
      key = feature.is_a?(String) ? feature.to_sym : feature
      entry = registry.find { |item| item.name == key }
      raise ArgumentError, "unknown feature #{feature.inspect}" unless entry

      entry
    end

    # Fixed-context features always use their declared context. Session-context
    # features use the passed context, and refuse a missing or nil one.
    def bind_context(entry, context)
      return entry.context unless entry.context.nil?
      return context unless keyword_omitted?(context) || context.nil?

      raise ArgumentError, "feature #{entry.name} runs under the session's bound context; pass context:"
    end

    def keyword_omitted?(context) = context.equal?(OMITTED)

    # Fixed-context features are served under their own context. Session-context
    # features are omitted when context: was not passed, and otherwise judged
    # under the context that was.
    def served_for?(surface, entry, context)
      return served?(surface, entry, entry.context) unless entry.context.nil?
      return false if keyword_omitted?(context)

      served?(surface, entry, context)
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
      cached_surface(resolved_inventory_dir(root, tag), tag)
    end

    # Absolute directory for this build. A directory that exists is canonical
    # (symlinks and ".." collapsed) so two spellings share one cache entry.
    def resolved_inventory_dir(root, tag)
      path = File.expand_path(File.join(root, tag))
      File.directory?(path) ? File.realpath(path) : path
    end

    def cached_surface(dir, tag)
      CACHE_MUTEX.synchronize do
        surfaces = (@surfaces ||= {})
        surfaces[dir] ||= read_surface(dir, tag)
      end
    end

    # The parsed rpms-ops lock, read once per path until reset!.
    def pinned_lock
      path = LOCK_PATH
      CACHE_MUTEX.synchronize do
        if @pinned_lock && @pinned_lock_path == path
          @pinned_lock
        else
          raise ArgumentError, "lock file is missing: #{path}" unless File.file?(path)

          @pinned_lock_path = path
          @pinned_lock = Conformance::InventoryLock.load(path)
        end
      end
    end

    def read_surface(dir, tag)
      registry_path = File.join(dir, "#{tag}-broker_8994.txt")
      reach = File.join(dir, "#{tag}-rpc_reach.txt")
      raise ArgumentError, "reach face is missing for build #{tag}" unless File.file?(reach)
      raise ArgumentError, "registry is missing for build #{tag}" unless File.file?(registry_path)

      reject_duplicate_rows!(registry_path)
      reject_duplicate_rows!(reach)
      Conformance::BuildSurface.from_files(tag: tag, registry: registry_path, reach: reach)
    rescue Conformance::BuildSurface::Error => e
      # The reader's reason (order, empty face, unknown reach class) is the
      # ArgumentError message. Same treatment for any BuildSurface::Error this
      # read raises.
      raise ArgumentError, e.message
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
