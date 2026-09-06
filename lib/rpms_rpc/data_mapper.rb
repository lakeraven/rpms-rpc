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
    Field = Struct.new(:position, :attribute, :type, :terminology, :pointer, keyword_init: true)

    # BMX GLOBAL-ARRAY (recordset) RPC replies open with a typed column-header
    # row, append a $C(30) record separator to every row, and close with a bare
    # $C(31) (e.g. SEARCH^BSDX24 writes "T00030RESOURCENAME^..."_$C(30), then
    # $C(31)). The parse paths below strip that framing so recordset reads get
    # DATA rows — previously only Scheduling#error_write did, and every
    # fetch_one/fetch_many recordset read parsed the header row as data.
    RECORDSET_SEPARATORS = /[\u001E\u001F]+\z/

    # Trailing $C(30)/$C(31) record/end separators removed.
    def self.strip_recordset_separators(line)
      line.to_s.sub(RECORDSET_SEPARATORS, "")
    end

    # A recordset column-header row: every caret piece is a type char
    # (I/T/D/F) followed by a 5-digit width and the column name (e.g.
    # "I00020APPOINTMENTID^T00020ERRORID"). Data rows never match.
    def self.recordset_header_row?(line)
      s = strip_recordset_separators(line)
      return false if s.empty?

      s.split("^", -1).all? { |piece| piece.match?(/\A[ITDF]\d{5}/) }
    end

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

      def field(position, attribute, type = :string, terminology: nil, pointer: nil)
        @fields << Field.new(position: position, attribute: attribute, type: type,
                             terminology: terminology, pointer: pointer)
      end

      # Declare a line-based field (one field per response line, not per caret).
      # Used for RPCs like XUS AV CODE where each line has a distinct meaning.
      def line_field(line_number, attribute, type = :string)
        @line_fields ||= []
        @line_fields << Field.new(position: line_number, attribute: attribute, type: type)
      end

      # Declare a scalar response (single value, no structure).
      # Used for RPCs like ORWPT DIEDON that return one value.
      def scalar(attribute, type = :string)
        @scalar_attribute = attribute
        @scalar_type = type
      end

      # Declare a text blob response (array of lines joined with newlines).
      # Used for RPCs like ORWRP REPORT TEXT that return free text.
      def text_blob(attribute)
        @text_attribute = attribute
      end

      def text_blob?
        !@text_attribute.nil?
      end

      def scalar?
        !@scalar_attribute.nil?
      end

      def terminology_fields
        @fields.select { |f| !f.terminology.nil? }
      end

      def pointer_fields
        @fields.select { |f| !f.pointer.nil? }
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
      # Brokers occasionally return a bare String where a list is expected —
      # previously that crashed on String#filter_map. A broker error string
      # ("-1^message") yields no rows (never a bogus record built from the
      # error text); any other String is split into its lines.
      def parse_many(response)
        return [] if response.nil? || response.empty?

        if response.is_a?(String)
          return [] if response.start_with?("-1^")

          response = response.split(/\r?\n/)
        end
        response.filter_map do |line|
          next if line.nil? || line.to_s.empty?
          next if DataMapper.recordset_header_row?(line)
          parse_one(line)
        end
      end

      # Parse a line-based response where each LINE is a different field.
      def parse_lines(response, extras: {})
        return nil if response.nil? || response.empty?

        result = {}
        (@line_fields || []).each do |f|
          raw = response[f.position]
          result[f.attribute] = raw.nil? ? nil : coerce(raw.to_s, f.type)
        end

        extras.each { |k, v| result[k] = v }
        result
      end

      # Parse a scalar response (single value).
      def parse_scalar(response)
        line = normalize_line(response)
        return nil if line.nil? || line.empty?

        coerce(line, @scalar_type || :string)
      end

      # Parse a text blob response (join lines with newlines).
      def parse_text(response)
        return nil if response.nil?
        return nil if response.is_a?(Array) && response.empty?
        return response if response.is_a?(String) && !response.empty?
        return nil if response.is_a?(String) && response.empty?

        response.join("\n")
      end

      # -- format_* methods: reverse of parse (hash → caret-delimited string) ----

      # Format a hash into a caret-delimited string matching this mapping's field positions.
      def format_one(attrs)
        max_pos = @fields.map(&:position).max || 0
        parts = Array.new(max_pos + 1, "")

        @fields.each do |f|
          val = attrs[f.attribute]
          parts[f.position] = format_value(val, f.type)
        end

        parts.join("^")
      end

      # Format an array of hashes into an array of caret-delimited strings.
      def format_many(attrs_list)
        attrs_list.map { |attrs| format_one(attrs) }
      end

      # Format a scalar value for this mapping's scalar type.
      def format_scalar(value)
        format_value(value, @scalar_type || :string)
      end

      # -- fetch_* methods: call RPC + parse in one shot -------------------------
      #
      # All fetch methods use RpmsRpc.client (configured at boot or via RpmsRpc.mock!).

      def fetch_one(*params, extras: {})
        response = RpmsRpc.client.call_rpc(rpc_name, *params)
        return nil if response.nil? || response.empty?

        parse_one(response, extras: extras)
      end

      def fetch_many(*params)
        response = RpmsRpc.client.call_rpc(rpc_name, *params)
        return [] if response.nil? || response.empty?

        parse_many(response)
      end

      def fetch_scalar(*params)
        response = RpmsRpc.client.call_rpc(rpc_name, *params)
        return nil if response.nil? || response.empty?

        parse_scalar(response)
      end

      def fetch_text(*params)
        response = RpmsRpc.client.call_rpc(rpc_name, *params)
        return nil if response.nil? || response.empty?

        parse_text(response)
      end

      def fetch_lines(*params, extras: {})
        response = RpmsRpc.client.call_rpc(rpc_name, *params)
        return nil if response.nil? || response.empty?

        parse_lines(response, extras: extras)
      end

      private

      def format_value(val, type)
        return "" if val.nil?

        case type
        when :fileman_date
          val.is_a?(Date) || val.is_a?(Time) ? FilemanDateParser.format_date(val) : val.to_s
        when :fileman_datetime
          val.is_a?(Date) || val.is_a?(Time) ? FilemanDateParser.format_datetime(val) : val.to_s
        when :integer
          val.to_s
        when :boolean
          val ? "1" : "0"
        else
          val.to_s
        end
      end

      # First DATA line of a response: recordset header rows and $C(30)/$C(31)
      # separators (see RECORDSET_SEPARATORS) are not data.
      def normalize_line(response)
        return nil if response.nil?
        return nil if response.is_a?(String) && response.empty?

        if response.is_a?(Array)
          return response.lazy
                         .map { |l| DataMapper.strip_recordset_separators(l) }
                         .reject { |l| l.empty? || DataMapper.recordset_header_row?(l) }
                         .first
        end

        DataMapper.strip_recordset_separators(response)
      end

      def coerce(raw, type)
        return nil if raw.nil? || raw.empty?

        case type
        when :string
          raw
        when :integer
          raw.to_i
        when :float
          Float(raw)
        when :fileman_date
          FilemanDateParser.parse_date(raw)
        when :fileman_datetime
          FilemanDateParser.parse_datetime(raw)
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

    def self.method_missing(name, ...)
      return @registry.fetch(name) if @registry.key?(name)

      super
    end

    def self.respond_to_missing?(name, include_private = false)
      @registry.key?(name) || super
    end
  end
end
