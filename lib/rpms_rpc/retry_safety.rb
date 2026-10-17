# frozen_string_literal: true

require "yaml"

module RpmsRpc
  # Retry-safety classes for the public API (rpms-rpc#110).
  #
  # The gem never retries. Hosts consult this table before doing so: only
  # :read is safe to retry on its own, and a method with no entry is not.
  module RetrySafety
    extend self

    CLASSES = %i[read idempotent_write non_idempotent_write].freeze
    PATH = File.expand_path("retry_safety.yml", __dir__).freeze

    # Keys are the real method name, including a trailing ?, !, or =.
    # One walk of the node tree: safe_load would apply "<<" and keep the last duplicate.
    def load(path)
      stream = File.open(path, "r:bom|utf-8") { |file| Psych.parse_stream(file, filename: path) }
      raise ArgumentError, "retry safety document is not a Hash" unless stream.children.one?

      mapping = stream.children.first.root
      raise ArgumentError, "retry safety document is not a Hash" unless mapping.is_a?(Psych::Nodes::Mapping)

      table = {}
      mapping.children.each_slice(2) do |key_node, value_node|
        key = string_key(key_node, value_node)
        raise ArgumentError, "retry safety duplicate key #{key}" if table.key?(key)

        table[key] = classification(key, value_node)
      end
      table.freeze
    end

    def table
      @table ||= load(PATH)
    end

    def for(mod, method_name)
      table.fetch("#{module_name(mod)}.#{method_name}")
    end

    # True only for :read. An unclassified method is not retry-safe.
    def auto_retry_safe?(mod, method_name)
      self.for(mod, method_name) == :read
    rescue KeyError
      false
    end

    def lint(labels, table)
      {
        unclassified: (labels - table.keys).sort,
        stale: (table.keys - labels).sort
      }
    end

    private

    def module_name(mod)
      mod.is_a?(Module) ? mod.name : mod.to_s
    end

    def string_key(key_node, value_node)
      plain_scalar!(key_node)
      key = scalar_object(key_node)
      raise ArgumentError, "retry safety key #{key}" if key == "<<"
      return key if key.is_a?(String) && quoted_or_plain?(key_node)

      shown = value_inspect(value_node)
      extra = shown ? " value #{shown}" : ""
      raise ArgumentError, "retry safety key #{key.inspect}#{extra} is not a String key"
    end

    def classification(key, node)
      plain_scalar!(node, key)
      value = scalar_object(node)
      klass = value.to_sym if value.is_a?(String) && quoted_or_plain?(node)
      return klass if CLASSES.include?(klass)

      raise ArgumentError, "retry safety #{key} has class #{value.inspect}"
    end

    def plain_scalar!(node, key = nil)
      return if node.is_a?(Psych::Nodes::Scalar) && node.tag.nil? && node.anchor.nil?

      raise ArgumentError, "retry safety key #{key || node_label(node)}"
    end

    def quoted_or_plain?(node)
      node.plain || node.style == Psych::Nodes::Scalar::SINGLE_QUOTED ||
        node.style == Psych::Nodes::Scalar::DOUBLE_QUOTED
    end

    def scalar_object(node)
      return node.value unless node.plain

      scanner.tokenize(node.value)
    end

    def value_inspect(node)
      return unless node.is_a?(Psych::Nodes::Scalar) && node.tag.nil? && node.anchor.nil?

      scalar_object(node).inspect
    end

    def node_label(node)
      case node
      when Psych::Nodes::Scalar then node.value
      when Psych::Nodes::Alias then "*#{node.anchor}"
      else node.class.name
      end
    end

    def scanner
      @scanner ||= Psych::ScalarScanner.new(Psych::ClassLoader.new)
    end
  end
end
