# frozen_string_literal: true

require_relative "fileman_date_parser"

module RpmsRpc
  # Declarative mapping from RPMS RPC caret-delimited responses to hashes.
  #
  # Define a mapping once:
  #
  #   RpmsRpc::DataMapper.define(:patient_select) do |m|
  #     m.rpc "ORWPT SELECT"
  #     m.field 0, :name
  #     m.field 1, :sex
  #     m.field 2, :dob, :fileman_date
  #     m.field 3, :ssn
  #     m.field 14, :age, :integer
  #   end
  #
  # Parse a single-line response:
  #
  #   RpmsRpc::DataMapper[:patient_select].parse_one(response, extras: { dfn: 42 })
  #   # => { name: "DOE,JOHN", sex: "M", dob: #<Date: 1980-01-15>, ssn: "111223333", age: 45, dfn: 42 }
  #
  # Parse a multi-line response (search results):
  #
  #   RpmsRpc::DataMapper[:patient_list].parse_many(response)
  #   # => [{ dfn: 1, name: "DOE,JOHN" }, { dfn: 2, name: "SMITH,JANE" }]
  #
  module DataMapper
    Field = Struct.new(:position, :attribute, :type, keyword_init: true)

    class Mapping
      attr_reader :name, :rpc_name, :fields

      def initialize(name)
        @name = name
        @rpc_name = nil
        @fields = []
      end

      # Configure this mapping using a block.
      # Uses instance_exec so the block can call rpc/field directly.
      # Safe: blocks are developer-defined at load time, not user input.
      def configure(&block)
        instance_exec(&block) # rubocop:disable Security/Eval
      end

      def rpc(name)
        @rpc_name = name
      end

      def field(position, attribute, type = :string)
        @fields << Field.new(position: position, attribute: attribute, type: type)
      end

      # Parse a single-line RPC response into a hash.
      def parse_one(response, extras: {})
        line = normalize_line(response)
        return nil if line.nil? || line.empty?

        parts = line.split("^", -1)
        result = {}

        @fields.each do |f|
          raw = parts[f.position]
          result[f.attribute] = coerce(raw, f.type)
        end

        extras.each { |k, v| result[k] = v }
        result
      end

      # Parse a multi-line RPC response into an array of hashes.
      def parse_many(response)
        return [] if response.nil? || response.empty?

        response.filter_map do |line|
          next if line.nil? || line.to_s.empty?
          parse_one(line)
        end
      end

      private

      def normalize_line(response)
        return nil if response.nil?
        return nil if response.is_a?(String) && response.empty?

        if response.is_a?(Array)
          return nil if response.empty?
          return response.first.to_s
        end

        response.to_s
      end

      def coerce(raw, type)
        return nil if raw.nil? || raw.empty?

        case type
        when :string
          raw
        when :integer
          raw.to_i
        when :fileman_date
          FilemanDateParser.parse_date(raw)
        when :boolean
          raw == "1" || raw.casecmp?("yes")
        else
          raw
        end
      end
    end

    @registry = {}

    def self.define(name, &block)
      mapping = Mapping.new(name)
      if block.arity == 1
        block.call(mapping)
      else
        mapping.configure(&block)
      end
      @registry[name] = mapping
      mapping
    end

    def self.[](name)
      @registry.fetch(name)
    end
  end
end
