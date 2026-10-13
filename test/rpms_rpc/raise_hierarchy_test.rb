# frozen_string_literal: true

require "minitest/autorun"
require "prism"

LIB_DIR = File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift(LIB_DIR) unless $LOAD_PATH.include?(LIB_DIR)
Dir[File.join(LIB_DIR, "rpms_rpc", "**", "*.rb")].sort.each { |path| require path }

# Every exception the gem raises descends from RpmsRpc::Error, so a host can
# rescue RPMS failures in one place (#357, acceptance criterion 3; ADR 0010,
# assertion 4).
#
# The test reads every `raise` and `fail` in lib/ and resolves the class each
# one raises, from the constant's lexical scope:
#
#   raise Foo, "..."            Foo
#   raise Foo.new("...")        Foo
#   raise error                 the class `error` was last assigned from, in
#                               the same method (Foo.new or a factory below)
#   raise Client.rpc_error_for  a factory whose every answer is in the hierarchy
#   raise                       a re-raise inside a rescue; it adds no class
#
# Anything it cannot resolve fails, so a new raise either names its class or
# extends this test.
class RaiseHierarchyTest < Minitest::Test
  # Raised for a caller's mistake, never for an RPMS failure: a host fixes its
  # code rather than rescuing these, so they stay Ruby's own.
  #   ArgumentError        a bad argument (Problem.add without a Hash)
  #   NotImplementedError  an abstract method a subclass must define
  PROGRAMMER_ERRORS = [ ArgumentError, NotImplementedError ].freeze

  # Methods that answer an error class rather than raise one.
  FACTORIES = {
    "Client.rpc_error_for" => -> { [ RpmsRpc::Client::RpcNotAvailableError, RpmsRpc::Client::RpcRefusedError, RpmsRpc::Client::RpcError ] }
  }.freeze

  Site = Struct.new(:path, :line, :source, :raised, keyword_init: true)

  # Walks one file's syntax tree, recording each raise and the class it raises
  # (a Class, or a String saying why it could not be resolved).
  class RaiseVisitor < Prism::Visitor
    attr_reader :sites

    def initialize(path)
      super()
      @path = path
      @nesting = []
      @defs = []
      @sites = []
    end

    def visit_module_node(node) = within(node) { super }
    def visit_class_node(node) = within(node) { super }

    def visit_def_node(node)
      @defs.push(node)
      super
    ensure
      @defs.pop
    end

    def visit_call_node(node)
      if node.receiver.nil? && %i[raise fail].include?(node.name)
        first = node.arguments&.arguments&.first
        @sites << Site.new(path: @path, line: node.location.start_line,
                           source: node.slice.lines.first.strip, raised: raised_class(first, node))
      end
      super
    end

    private

    def within(node)
      name = node.constant_path.full_name
      @nesting.push(@nesting.empty? || name.start_with?("::") ? name.delete_prefix("::") : "#{@nesting.last}::#{name}")
      yield
    ensure
      @nesting.pop
    end

    def raised_class(arg, call)
      case arg
      when nil then :reraise
      when Prism::ConstantReadNode, Prism::ConstantPathNode then resolve(arg.full_name)
      when Prism::CallNode then from_call(arg)
      when Prism::LocalVariableReadNode then from_assignment(arg.name, call)
      else "cannot resolve #{arg.class.name.split('::').last}: #{arg.slice}"
      end
    end

    def from_call(call)
      receiver = call.receiver
      return "cannot resolve #{call.slice}" unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
      return resolve(receiver.full_name) if call.name == :new

      factory = FACTORIES["#{receiver.full_name}.#{call.name}"]
      factory ? factory.call : "#{receiver.full_name}.#{call.name} is not a known error factory"
    end

    # The last `name = ...` before the raise, in the same method.
    def from_assignment(name, call)
      scope = @defs.last or return "cannot resolve #{name}: not inside a method"
      writes = []
      scope.body&.accept(WriteCollector.new(name, writes))
      write = writes.select { |w| w.location.start_offset < call.location.start_offset }.last
      return "cannot resolve #{name}: no assignment before the raise" unless write

      value = write.value
      value.is_a?(Prism::CallNode) ? from_call(value) : "cannot resolve #{name} = #{value.slice}"
    end

    def resolve(name)
      return Object.const_get(name.delete_prefix("::")) if name.start_with?("::")

      @nesting.reverse_each do |scope|
        return Object.const_get("#{scope}::#{name}")
      rescue NameError
        next
      end
      Object.const_get(name)
    rescue NameError
      "cannot resolve constant #{name}"
    end
  end

  class WriteCollector < Prism::Visitor
    def initialize(name, writes)
      super()
      @name = name
      @writes = writes
    end

    def visit_local_variable_write_node(node)
      @writes << node if node.name == @name
      super
    end
  end

  def sites
    @sites ||= Dir[File.join(LIB_DIR, "**", "*.rb")].sort.flat_map do |path|
      visitor = RaiseVisitor.new(path.delete_prefix("#{File.dirname(LIB_DIR)}/"))
      Prism.parse_file(path).value.accept(visitor)
      visitor.sites
    end
  end

  def test_every_raise_in_lib_raises_an_rpms_rpc_error
    outside = sites.reject { |site| site.raised == :reraise }.filter_map do |site|
      classes = Array(site.raised)
      bad = classes.reject { |c| c.is_a?(Class) && (c <= RpmsRpc::Error || PROGRAMMER_ERRORS.include?(c)) }
      next if bad.empty?

      "#{site.path}:#{site.line}  #{site.source}  -> #{bad.map { |c| c.is_a?(Class) ? "#{c} (not an RpmsRpc::Error)" : c }.join(', ')}"
    end

    assert_empty outside, "raises outside the RpmsRpc::Error hierarchy (#357); raise a subclass of " \
                          "RpmsRpc::Error, or say here why a class is exempt:\n#{outside.join("\n")}"
  end

  # The walk would pass vacuously if it found nothing: it must see the gem's
  # raises, including each form it resolves.
  def test_the_walk_sees_each_form_of_raise
    by_form = sites.group_by do |site|
      next :reraise if site.raised == :reraise

      case site.source
      when /\b(raise|fail)\(?\s*error\b/ then :variable
      when /rpc_error_for/ then :factory
      when /\.new\b/ then :new
      else :constant
      end
    end

    assert_operator sites.size, :>, 100, "the walk found only #{sites.size} raises in lib/"
    %i[constant variable factory reraise].each do |form|
      refute_empty by_form.fetch(form, []), "the walk saw no #{form} raise; is the visitor still reading lib/?"
    end
  end

  def test_an_unknown_class_is_reported_not_ignored
    visitor = RaiseVisitor.new("example.rb")
    Prism.parse(<<~RUBY).value.accept(visitor)
      module RpmsRpc
        def self.go(x)
          raise RuntimeError, "plain"
          raise NoSuchErrorClass
          raise x
          raise Client::ConnectionError, "typed"
        end
      end
    RUBY

    raised = visitor.sites.map(&:raised)
    assert_equal RuntimeError, raised[0]
    assert_equal "cannot resolve constant NoSuchErrorClass", raised[1]
    assert_match(/cannot resolve x/, raised[2])
    assert_equal RpmsRpc::Client::ConnectionError, raised[3]
  end
end
