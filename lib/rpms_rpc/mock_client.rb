# frozen_string_literal: true

require_relative "data_mapper"
require_relative "mappings"

module RpmsRpc
  # Mock RPC client for testing. Consumers seed data as hashes;
  # MockClient formats them into caret-delimited RPC responses
  # using the DataMapper mappings. High fidelity — responses go
  # through the same parse path as production.
  #
  #   RpmsRpc.mock! do |m|
  #     m.seed(:patient_select, "1", { name: "DOE,JOHN", sex: "M" })
  #     m.seed_collection(:patient_list, [{ dfn: 1, name: "DOE,JOHN" }], filter_field: :name)
  #   end
  #
  class MockClient
    def initialize
      @records = {}     # { rpc_name => { key => formatted_string } }
      @collections = {} # { rpc_name => { lines: [...], filter_field: Symbol?, filter_pos: Integer? } }
      @scalars = {}     # { rpc_name => { key => formatted_string } }
    end

    # Seed a single record for a mapping.
    def seed(mapping_name, key, attrs)
      mapping = DataMapper[mapping_name]
      formatted = mapping.format_one(attrs)
      @records[mapping.rpc_name] ||= {}
      @records[mapping.rpc_name][key.to_s] = formatted
    end

    # Seed a collection (search results) for a mapping.
    # filter_field: attribute name to filter by (first RPC param used as prefix match).
    def seed_collection(mapping_name, attrs_list, filter_field: nil)
      mapping = DataMapper[mapping_name]
      formatted = mapping.format_many(attrs_list)

      filter_pos = nil
      if filter_field
        f = mapping.fields.find { |ff| ff.attribute == filter_field }
        filter_pos = f&.position
      end

      @collections[mapping.rpc_name] = { lines: formatted, filter_pos: filter_pos }
    end

    # Seed a scalar value for a mapping.
    def seed_scalar(mapping_name, key, value)
      mapping = DataMapper[mapping_name]
      formatted = mapping.format_scalar(value)
      @scalars[mapping.rpc_name] ||= {}
      @scalars[mapping.rpc_name][key.to_s] = formatted
    end

    # Seed a line-based response for a mapping (e.g., XUS AV CODE).
    # attrs is a hash matching the mapping's line_fields; stored as an array of lines.
    def seed_lines(mapping_name, key, attrs)
      mapping = DataMapper[mapping_name]
      line_fields = mapping.instance_variable_get(:@line_fields) || []
      max_line = line_fields.map(&:position).max || 0
      lines = Array.new(max_line + 1, "")
      line_fields.each do |f|
        val = attrs[f.attribute]
        lines[f.position] = val.nil? ? "" : val.to_s
      end
      @lines ||= {}
      @lines[mapping.rpc_name] ||= {}
      @lines[mapping.rpc_name][key.to_s] = lines
    end

    # Seed a keyed collection — different keys return different result sets.
    # Unlike seed_collection (one set for all keys), this stores per-key arrays.
    def seed_keyed_collection(mapping_name, key, attrs_list)
      mapping = DataMapper[mapping_name]
      formatted = mapping.format_many(attrs_list)
      @keyed_collections ||= {}
      @keyed_collections[mapping.rpc_name] ||= {}
      @keyed_collections[mapping.rpc_name][key.to_s] = formatted
    end

    # Seed a complete user for authentication testing.
    # Handles all the RPMS-specific mapping internally — callers use domain terms only.
    #
    #   m.seed_user("301",
    #     credentials: "testprovider;test123",
    #     name: "PROVIDER,TEST",
    #     role: :provider,
    #     security_keys: [:prc_supervisor, :cprs_gui_chart])
    #
    def seed_user(duz, credentials:, name:, role:, security_keys: [])
      require_relative "security_keys"
      require_relative "user_roles"

      # Credential response
      seed_lines(:av_code, credentials, { duz: duz.to_i, greeting: "Welcome #{name}", tries: 3 })

      # User info
      seed(:user_info, duz.to_s, UserRoles.mock_user_info(duz: duz, name: name, role: role))

      # Security keys (symbolic → RPMS strings)
      rpms_keys = security_keys.filter_map { |sym| SecurityKeys.rpms_name(sym) }
      key_attrs = rpms_keys.map { |k| { key_name: k } }
      seed_keyed_collection(:user_keys, duz.to_s, key_attrs)
    end

    # Simulate call_rpc — returns formatted response matching the seeded data.
    def call_rpc(rpc_name, *params)
      key = params.first.to_s

      # Line-based responses (keyed by first param)
      if @lines&.dig(rpc_name, key)
        return @lines[rpc_name][key]
      end

      # Single records (keyed by first param)
      if @records.dig(rpc_name, key)
        return [ @records[rpc_name][key] ]
      end

      # Keyed collections (keyed by first param)
      if @keyed_collections&.dig(rpc_name, key)
        return @keyed_collections[rpc_name][key]
      end

      # Collections (optionally filtered by first param)
      if (col = @collections[rpc_name])
        return filter_collection(col, key)
      end

      # Scalars (keyed by first param)
      if @scalars.dig(rpc_name, key)
        return @scalars[rpc_name][key]
      end

      ""
    end

    private

    def filter_collection(col, pattern)
      lines = col[:lines]
      filter_pos = col[:filter_pos]

      return lines if filter_pos.nil? || pattern.empty?

      filtered = lines.select do |line|
        field_val = line.to_s.split("^")[filter_pos].to_s
        field_val.upcase.start_with?(pattern.upcase)
      end

      filtered.empty? ? "" : filtered
    end
  end
end
