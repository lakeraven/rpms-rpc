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
    # Auto-detects mapping type: text_blob stores raw text,
    # scalar stores formatted scalar, field-based formats to caret-delimited.
    def seed(mapping_name, key, attrs)
      mapping = DataMapper[mapping_name]

      if mapping.text_blob? && attrs.is_a?(String)
        seed_text(mapping_name, key, attrs)
      elsif mapping.scalar?
        seed_scalar(mapping_name, key, attrs.is_a?(Hash) ? attrs.values.first : attrs)
      else
        formatted = mapping.format_one(attrs)
        @records[mapping.rpc_name] ||= {}
        @records[mapping.rpc_name][key.to_s] = formatted
      end
    end

    # Seed raw text for a text_blob mapping.
    def seed_text(mapping_name, key, text)
      mapping = DataMapper[mapping_name]
      @text_blobs ||= {}
      @text_blobs[mapping.rpc_name] ||= {}
      @text_blobs[mapping.rpc_name][key.to_s] = text
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

      user_class = UserRoles.class_for(role) || "0"

      # Credential response
      seed_lines(:av_code, credentials.to_s.strip.upcase, {
        duz: duz.to_i,
        error_code: 0,
        verify_needs_change: 0,
        message: "Welcome #{name}",
        user_class: user_class.to_i
      })

      # User info (XUS GET USER INFO — line-based, no params; mock matches
      # the live shape: one value per response line).
      seed_lines(:user_info, "", {
        duz: duz.to_i,
        name: name,
        display_name: name,
        current_site: "",
        user_class: user_class.to_i
      })

      # Security keys (symbolic → RPMS strings)
      rpms_keys = security_keys.filter_map { |sym| SecurityKeys.rpms_name(sym) }
      key_attrs = rpms_keys.map { |k| { key_name: k } }
      seed_keyed_collection(:user_keys, duz.to_s, key_attrs)
    end

    # Records of every call_rpc invocation, for tests that need to assert on
    # outgoing payloads (e.g. write RPCs that take complex multi-line params).
    # Each entry: { rpc:, params: [...] }
    def received_calls
      @received_calls ||= []
    end

    # Pre-populate a ServerCapabilities answer so `supports?` short-circuits
    # without probing. Default is `true` (preserve backward compatibility:
    # tests that don't seed see all features as available).
    def seed_capability(feature, supported: true)
      @capability_seeds ||= {}
      @capability_seeds[feature] = supported
    end

    def supports?(feature)
      @capability_seeds ||= {}
      @capability_seeds.fetch(feature, true)
    end

    # Simulate call_rpc — returns formatted response matching the seeded data.
    def call_rpc(rpc_name, *params)
      received_calls << { rpc: rpc_name, params: params }
      key = params.first.to_s

      # Line-based responses (keyed by first param)
      if @lines&.dig(rpc_name, key)
        return @lines[rpc_name][key]
      end

      # Text blob responses (keyed by first param)
      if @text_blobs&.dig(rpc_name, key)
        text = @text_blobs[rpc_name][key]
        return text.include?("\n") ? text.split("\n") : text
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
