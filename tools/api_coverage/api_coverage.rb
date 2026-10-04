# frozen_string_literal: true

require "prism"
require "json"
require "yaml"

# API coverage (rpms-rpc#358, ADR 0010 assertion 2): which public methods of the API modules a live
# spec proves. Generated from the code each run; there is no hand-maintained list.
#
#   methods     every public singleton method of a module under RpmsRpc whose source is in
#               lib/rpms_rpc/api/ (RpmsRpc::Patient.find, RpmsRpc::BehavioralHealth::Groups.list, ...)
#   rpcs        the RPC names the method sends, by static analysis of its body and of every
#               lib/rpms_rpc method it calls (receiverless helpers, Module.method calls):
#               DataMapper mappings (DataMapper.x, DataMapper[:x], or a :x symbol argument that names
#               a mapping) resolve through the loaded mapping registry; call_rpc* with a string literal
#               or a String constant resolves to that string. Anything else is reported as unresolved,
#               never guessed.
#   registered  whether each RPC is a #8994 NAME on the pinned registry (data/rpc_coverage/config.yml),
#               with its entry point TAG^ROUTINE
#   live_specs  every `RpmsRpc::Module.method` call site under test/live/ (static)
#   status      proven (a live spec calls it) or not_in_contract (none does)
#
# "proven" is static: a live spec calls the method. Whether that spec passes is `rake test:live`'s
# answer, run per persona. Lives under tools/ so it never ships in the gem.
module ApiCoverage
  STATUSES = %w[proven not_in_contract].freeze
  # The live harness (test/live/live_helper.rb) signs on as whichever persona the run's PERSONA names,
  # and runs every spec under it; a spec has no way to declare a persona of its own. So every live
  # spec runs as both personas ADR 0010 names.
  PERSONAS = %w[least-privilege programmer].freeze
  RPC_SENDERS = /\Acall_rpc/ # call_rpc, call_rpc_raw, call_rpc_lines, call_rpc_global_array
  # Methods followed into when a public method calls them: module functions under lib/rpms_rpc/,
  # except DataMapper (its mappings are resolved, not followed) and the broker clients.
  NOT_FOLLOWED = %w[data_mapper.rb client.rb cia_client.rb xwb_client.rb bmx_client.rb mock_client.rb].freeze

  # What one method body references, before any resolution.
  #   mappings    DataMapper mapping names it names (DataMapper.x, DataMapper[:x], a :x argument to a
  #               receiverless call)
  #   literals    string literals passed as the RPC name of a call_rpc*
  #   constants   constant names passed as the RPC name of a call_rpc*
  #   from_locals RPC names that come from a local or a parameter: [{ local:, text: }]
  #   unresolved  RPC-name expressions of any other shape (source text)
  #   calls       method calls to follow: [{ receiver: nil | "Const::Name", name:, args: [Prism nodes] }]
  #   locals      local => the node last assigned to it
  Scan = Struct.new(:mappings, :literals, :constants, :from_locals, :unresolved, :calls, :locals, keyword_init: true)

  module_function

  # --- the static pieces (pure) --------------------------------------------------------------

  # Every def in a parsed file, keyed by its start line. An attr_reader/attr_writer/attr_accessor
  # line maps to :attr (it reads or writes an ivar, and sends nothing).
  def defs_by_line(program)
    out = {}
    walk(program) do |n|
      if n.is_a?(Prism::DefNode)
        out[n.location.start_line] = n
      elsif n.is_a?(Prism::CallNode) && n.receiver.nil? && n.name.to_s.start_with?("attr_")
        out[n.location.start_line] ||= :attr
      end
    end
    out
  end

  # The references in one def. mapping_names: the DataMapper registry's names (Symbols).
  def scan_def(def_node, mapping_names)
    s = Scan.new(mappings: [], literals: [], constants: [], from_locals: [], unresolved: [], calls: [], locals: {})
    walk(def_node.body) do |n|
      s.locals[n.name] = n.value if n.is_a?(Prism::LocalVariableWriteNode)
      next unless n.is_a?(Prism::CallNode)

      args = n.arguments&.arguments || []
      if data_mapper?(n.receiver)
        scan_data_mapper_call(n, args, mapping_names, s)
      elsif n.name.to_s.match?(RPC_SENDERS)
        scan_rpc_name(args.first, s)
      elsif n.receiver.nil? || n.receiver.is_a?(Prism::SelfNode)
        s.calls << { receiver: nil, name: n.name, args: args }
      elsif (const = const_name(n.receiver))
        s.calls << { receiver: const, name: n.name, args: args }
      end
      next unless n.receiver.nil? # rows(:amhg_case_dates, ...): a mapping handed to a helper, not row[:ien]

      args.each { |a| s.mappings << a.unescaped.to_sym if a.is_a?(Prism::SymbolNode) && mapping_names.include?(a.unescaped.to_sym) }
    end
    %i[mappings literals constants from_locals unresolved].each { |k| s[k].uniq! }
    s
  end

  def scan_data_mapper_call(node, args, mapping_names, scan)
    if node.name == :[]
      arg = args.first
      case arg
      when Prism::SymbolNode then scan.mappings << arg.unescaped.to_sym
      when Prism::LocalVariableReadNode then scan.from_locals << { local: arg.name, text: node.slice }
      else scan.unresolved << node.slice
      end
    elsif mapping_names.include?(node.name)
      scan.mappings << node.name
    end
  end

  # The first argument of a call_rpc*: the RPC name.
  def scan_rpc_name(arg, scan)
    case arg
    when Prism::StringNode then scan.literals << arg.unescaped
    when Prism::ConstantReadNode, Prism::ConstantPathNode then scan.constants << const_name(arg)
    when Prism::LocalVariableReadNode then scan.from_locals << { local: arg.name, text: arg.slice }
    when Prism::CallNode
      if arg.name == :rpc_name && arg.receiver.is_a?(Prism::LocalVariableReadNode)
        scan.from_locals << { local: arg.receiver.name, text: arg.slice }
      elsif !(arg.name == :rpc_name && data_mapper_ref?(arg.receiver)) # DataMapper.x.rpc_name is scanned as mapping x
        scan.unresolved << arg.slice
      end
    else
      scan.unresolved << (arg ? arg.slice : "(no RPC name argument)")
    end
  end

  # The value each parameter of def_node takes at a call with these argument nodes:
  # { param => arg node }, positional by position, keywords by name. Splats are not bound.
  def bind_args(def_node, args)
    params = def_node.parameters
    return {} unless params

    positional = params.requireds + params.optionals
    out = {}
    args.reject { |a| a.is_a?(Prism::KeywordHashNode) }.each_with_index do |a, i|
      p = positional[i]
      out[p.name] = a if p.respond_to?(:name) && p.name
    end
    args.grep(Prism::KeywordHashNode).flat_map(&:elements).each do |el|
      out[el.key.unescaped.to_sym] = el.value if el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
    end
    out
  end

  def data_mapper?(node) = %w[DataMapper RpmsRpc::DataMapper].include?(const_name(node))

  def data_mapper_ref?(node) = node.is_a?(Prism::CallNode) && data_mapper?(node.receiver)

  def const_name(node)
    case node
    when Prism::ConstantReadNode then node.name.to_s
    when Prism::ConstantPathNode then node.full_name
    end
  rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
    nil
  end

  def walk(node, &blk)
    return unless node

    yield node
    node.compact_child_nodes.each { |c| walk(c, &blk) }
  end

  # `RpmsRpc::Module.method` call sites in live spec sources: { "RpmsRpc::Patient" => { find: ["test/live/x.rb:12"] } }.
  def live_call_sites(files, root:)
    out = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } }
    files.sort.each do |f|
      walk(Prism.parse_file(f).value) do |n|
        next unless n.is_a?(Prism::CallNode)

        const = const_name(n.receiver)
        next unless const&.start_with?("RpmsRpc::")

        out[const][n.name] << "#{rel(f, root)}:#{n.location.start_line}"
      end
    end
    out
  end

  # #8994 0-node lines (NAME^TAG^ROUTINE^...) -> { name => "TAG^ROUTINE" }.
  def load_registry(path)
    File.readlines(path, chomp: true).each_with_object({}) do |l, out|
      next if l.strip.empty? || l.start_with?("#")

      name, tag, routine = l.split("^", 4)
      out[name] = tag.to_s.empty? && routine.to_s.empty? ? nil : "#{tag}^#{routine}"
    end
  end

  def rel(path, root) = path.delete_prefix("#{File.expand_path(root)}/")

  # --- the loaded API ------------------------------------------------------------------------

  # Public methods of the API modules: [[module, method_name], ...], sorted.
  def public_methods_of(namespace, api_dir)
    api_dir = File.expand_path(api_dir)
    api_modules(namespace).flat_map do |mod|
      mod.public_methods.filter_map do |m|
        loc = mod.method(m).source_location
        [ mod, m ] if loc && File.expand_path(loc[0]).start_with?("#{api_dir}/")
      end
    end.sort_by { |mod, m| [ mod.name, m.to_s ] }
  end

  def api_modules(namespace, seen = {})
    namespace.constants(false).sort.flat_map do |c|
      next [] if namespace.autoload?(c)

      v = namespace.const_get(c, false)
      next [] unless v.instance_of?(Module) && v.name&.start_with?("#{namespace.name}::") && !seen[v]

      seen[v] = true
      [ v ] + api_modules(v, seen)
    end
  end

  # Resolves what a public method sends, following the lib/rpms_rpc methods it calls and binding
  # the arguments it passes them, so a helper that sends `call_rpc(rpc_name)` resolves to what each
  # caller passed as rpc_name.
  class Resolver
    def initialize(lib_dir:, mappings:)
      @lib_dir = File.expand_path(lib_dir)
      @mappings = mappings # { Symbol => rpc_name or nil }
      @parsed = {}
    end

    # { rpcs: [{ name:, via: }], unresolved: [String] } for receiver.method_name.
    def resolve(receiver, method_name)
      acc = { mappings: [], literals: [], unresolved: [] }
      visit(receiver, method_name, {}, acc, {})
      rpcs = acc[:mappings].uniq.filter_map do |m|
        next { name: @mappings[m], via: "mapping :#{m}" } if @mappings[m]

        acc[:unresolved] << "mapping :#{m} names no RPC"
        nil
      end
      rpcs += acc[:literals].uniq.map { |l| { name: l, via: "literal" } }
      { rpcs: rpcs.uniq { |r| r[:name] }.sort_by { |r| r[:name] }, unresolved: acc[:unresolved].uniq }
    end

    private

    # bindings: { param => [:mapping, Symbol] | [:literal, String] | [:unknown, text] } from the caller.
    def visit(receiver, method_name, bindings, acc, seen)
      meth = receiver.method(method_name)
      loc = meth.source_location
      return unless loc && followed?(loc[0])

      key = [ receiver, loc, bindings ]
      return if seen[key]

      seen[key] = true
      where = "#{receiver.name}.#{method_name}"
      node = ApiCoverage.defs_by_line(parse(loc[0]))[loc[1]]
      return if node == :attr
      return acc[:unresolved] << "#{where}: no def at #{ApiCoverage.rel(loc[0], @lib_dir)}:#{loc[1]}" unless node

      s = ApiCoverage.scan_def(node, @mappings.keys)
      acc[:mappings].concat(s.mappings)
      acc[:literals].concat(s.literals)
      acc[:unresolved].concat(s.unresolved.map { |u| "#{where}: #{u}" })
      ctx = { owner: meth.owner, receiver: receiver, bindings: bindings, locals: s.locals }
      s.constants.each { |c| add(value_of_const(c, ctx, c), acc, where) }
      s.from_locals.each { |l| add(local_value(l[:local], ctx) || [ :unknown, l[:text] ], acc, where) }
      s.calls.each { |c| follow(c, ctx, acc, seen) }
    end

    def follow(call, ctx, acc, seen)
      target = call[:receiver] ? lookup_const(ctx[:owner], ctx[:receiver], call[:receiver]) : ctx[:receiver]
      return unless target.is_a?(Module) && target.respond_to?(call[:name], true)

      loc = target.method(call[:name]).source_location
      return unless loc && followed?(loc[0])

      callee = ApiCoverage.defs_by_line(parse(loc[0]))[loc[1]]
      bindings = callee.is_a?(Prism::DefNode) ? ApiCoverage.bind_args(callee, call[:args]).transform_values { |n| value_of(n, ctx) } : {}
      visit(target, call[:name], bindings.compact, acc, seen)
    end

    def add(value, acc, where)
      kind, v = value
      case kind
      when :mapping then acc[:mappings] << v
      when :literal then acc[:literals] << v
      else acc[:unresolved] << "#{where}: RPC name from #{v}, which is not bound to a mapping or string"
      end
    end

    # What an argument or RPC-name node evaluates to, statically.
    def value_of(node, ctx, depth = 0)
      return nil if depth > 4

      case node
      when Prism::StringNode then [ :literal, node.unescaped ]
      when Prism::SymbolNode
        sym = node.unescaped.to_sym
        @mappings.key?(sym) ? [ :mapping, sym ] : nil
      when Prism::ConstantReadNode, Prism::ConstantPathNode then value_of_const(ApiCoverage.const_name(node), ctx, node.slice)
      when Prism::LocalVariableReadNode then local_value(node.name, ctx, depth)
      when Prism::CallNode then call_value(node, ctx, depth)
      end
    end

    def call_value(node, ctx, depth)
      if ApiCoverage.data_mapper?(node.receiver)
        arg = node.arguments&.arguments&.first
        return value_of(arg, ctx, depth + 1) if node.name == :[]

        @mappings.key?(node.name) ? [ :mapping, node.name ] : nil
      elsif node.name == :rpc_name
        value_of(node.receiver, ctx, depth + 1)
      end
    end

    def local_value(name, ctx, depth = 0)
      return ctx[:bindings][name] if ctx[:bindings].key?(name)

      value_of(ctx[:locals][name], ctx, depth + 1) if ctx[:locals].key?(name)
    end

    def value_of_const(name, ctx, text)
      value = lookup_const(ctx[:owner], ctx[:receiver], name)
      value.is_a?(String) ? [ :literal, value ] : [ :unknown, "constant #{text}" ]
    end

    # Constant lookup from the method's owner, the receiver, then their enclosing namespaces.
    def lookup_const(owner, receiver, name)
      scopes = [ owner, receiver ].flat_map { |m| nesting(m) }.uniq
      scopes.each do |scope|
        return scope.const_get(name) if scope.const_defined?(name)
      rescue NameError
        next
      end
      nil
    end

    def nesting(mod)
      parts = mod.name.to_s.split("::")
      parts.size.downto(1).map { |i| Object.const_get(parts.first(i).join("::")) }
    end

    def followed?(file)
      file = File.expand_path(file)
      file.start_with?("#{@lib_dir}/rpms_rpc/") && !NOT_FOLLOWED.include?(File.basename(file))
    end

    def parse(file) = (@parsed[file] ||= Prism.parse_file(file).value)
  end

  # --- the report ----------------------------------------------------------------------------

  # The whole report for a source checkout at root, with lib/rpms_rpc loaded:
  # { entries:, registry_tag: }. The registry is the pinned one in data/rpc_coverage/config.yml.
  def build(root)
    registry_path = File.expand_path(YAML.safe_load_file(File.join(root, "data/rpc_coverage/config.yml")).fetch("registry"), root)
    registry = load_registry(registry_path)
    raise "no #8994 names in #{registry_path}" if registry.empty?

    methods = public_methods_of(RpmsRpc, File.join(root, "lib/rpms_rpc/api"))
    raise "found no public API methods under lib/rpms_rpc/api (was it loaded?)" if methods.empty?

    resolver = Resolver.new(lib_dir: File.join(root, "lib"), mappings: mapping_rpcs)
    live = live_call_sites(Dir[File.join(root, "test/live/**/*.rb")], root: root)
    { entries: entries(methods, resolver: resolver, live: live, registry: registry),
      registry_tag: File.basename(registry_path, ".txt").delete_suffix("-broker_8994") }
  end

  # { mapping name => RPC name } for every loaded DataMapper mapping.
  def mapping_rpcs(data_mapper = RpmsRpc::DataMapper)
    data_mapper.instance_variable_get(:@registry).transform_values(&:rpc_name)
  end

  # One entry per public method. methods: [[module, name]]; live: live_call_sites output;
  # registry: load_registry output.
  def entries(methods, resolver:, live:, registry:)
    methods.map do |mod, m|
      r = resolver.resolve(mod, m)
      specs = live.dig(mod.name, m) || []
      {
        module: mod.name,
        method: m.to_s,
        arity: mod.method(m).arity,
        params: mod.method(m).parameters.map { |kind, name| { name: name.to_s, kind: kind.to_s } },
        rpcs: r[:rpcs].map { |x| { name: x[:name], registered: registry.key?(x[:name]), entry_point: registry[x[:name]], via: x[:via] } },
        unresolved: r[:unresolved],
        live_specs: specs,
        personas: specs.empty? ? [] : PERSONAS,
        status: specs.empty? ? "not_in_contract" : "proven"
      }
    end
  end

  def summary(entries)
    by_module = entries.group_by { |e| e[:module] }.transform_values do |es|
      { proven: es.count { |e| e[:status] == "proven" }, public: es.size }
    end
    {
      proven: entries.count { |e| e[:status] == "proven" },
      public: entries.size,
      unresolved_methods: entries.count { |e| e[:unresolved].any? },
      unregistered_rpcs: entries.flat_map { |e| e[:rpcs] }.reject { |r| r[:registered] }.map { |r| r[:name] }.uniq.sort,
      by_module: by_module.sort.to_h
    }
  end

  def document(entries, registry_tag:)
    { schema: 1, registry: registry_tag, personas: PERSONAS, summary: summary(entries), methods: entries }
  end

  def report_lines(entries)
    s = summary(entries)
    pct = s[:public].zero? ? 0.0 : 100.0 * s[:proven] / s[:public]
    lines = [ format("API coverage: %d / %d public methods proven by a live spec (%.1f%%)", s[:proven], s[:public], pct) ]
    s[:by_module].sort_by { |name, c| [ -c[:proven], -c[:public], name ] }.each do |name, c|
      lines << format("  %-48s %3d / %3d", name, c[:proven], c[:public])
    end
    lines << "unresolved: #{s[:unresolved_methods]} methods have an RPC name static analysis could not resolve"
    lines << "unregistered RPCs sent: #{s[:unregistered_rpcs].empty? ? 'none' : s[:unregistered_rpcs].join(', ')}"
    lines
  end

  def method_lines(entries)
    entries.map do |e|
      rpcs = e[:rpcs].map { |r| r[:registered] ? r[:name] : "#{r[:name]} (NOT REGISTERED)" }
      rpcs << "unresolved" if e[:unresolved].any?
      status = e[:status] == "proven" ? "proven (#{e[:live_specs].join(', ')})" : "not in the contract"
      "#{e[:module]}.#{e[:method]}\t#{rpcs.join('; ')}\t#{status}"
    end
  end
end
