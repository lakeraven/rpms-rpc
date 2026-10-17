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
    def load(path)
      reject_duplicate_keys(path)
      document = YAML.safe_load_file(path)
      raise ArgumentError, "retry safety document #{document.inspect} is not a Hash" unless document.is_a?(Hash)

      table = {}
      document.each { |key, value| table[string_key(key, value)] = classification(key, value) }
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

    # safe_load keeps the last duplicate, so read the root mapping scalars first.
    def reject_duplicate_keys(path)
      root = Psych.parse_file(path)
      return unless root.respond_to?(:children)

      mapping = root.children.find { |node| node.is_a?(Psych::Nodes::Mapping) }
      return unless mapping

      seen = {}
      mapping.children.each_with_index do |node, index|
        next unless index.even? && node.is_a?(Psych::Nodes::Scalar)
        raise ArgumentError, "retry safety duplicate key #{node.value}" if seen.key?(node.value)

        seen[node.value] = true
      end
    end

    def string_key(key, value)
      return key if key.is_a?(String)

      raise ArgumentError, "retry safety key #{key.inspect} value #{value.inspect} is not a String key"
    end

    def classification(key, value)
      klass = value.to_sym if value.is_a?(String)
      return klass if CLASSES.include?(klass)

      raise ArgumentError, "retry safety #{key} has class #{value.inspect}"
    end
  end
end
