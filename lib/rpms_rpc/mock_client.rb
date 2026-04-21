# frozen_string_literal: true

require_relative "data_mapper"
require_relative "mappings"

module RpmsRpc
  # Mock RPC client for testing. Consumers seed data as hashes;
  # MockClient formats them into caret-delimited RPC responses
  # using the DataMapper mappings. High fidelity — responses go
  # through the same parse path as production.
  #
  #   mock = RpmsRpc::MockClient.new
  #   mock.seed(:patient_select, "1", { name: "DOE,JOHN", sex: "M", dob: Date.new(1980,1,15) })
  #   mock.call_rpc("ORWPT SELECT", "1")  # => "DOE,JOHN^M^2800115^..."
  #
  class MockClient
    def initialize
      @records = {}     # { rpc_name => { key => formatted_string } }
      @collections = {} # { rpc_name => [formatted_string, ...] }
      @scalars = {}     # { rpc_name => { key => formatted_string } }
    end

    # Seed a single record for a mapping.
    # Key is typically the first RPC param (DFN, IEN, etc.).
    def seed(mapping_name, key, attrs)
      mapping = DataMapper[mapping_name]
      formatted = mapping.format_one(attrs)
      @records[mapping.rpc_name] ||= {}
      @records[mapping.rpc_name][key.to_s] = formatted
    end

    # Seed a collection (search results) for a mapping.
    def seed_collection(mapping_name, attrs_list)
      mapping = DataMapper[mapping_name]
      formatted = mapping.format_many(attrs_list)
      @collections[mapping.rpc_name] = formatted
    end

    # Seed a scalar value for a mapping.
    def seed_scalar(mapping_name, key, value)
      mapping = DataMapper[mapping_name]
      formatted = mapping.format_scalar(value)
      @scalars[mapping.rpc_name] ||= {}
      @scalars[mapping.rpc_name][key.to_s] = formatted
    end

    # Simulate call_rpc — returns formatted response matching the seeded data.
    def call_rpc(rpc_name, *params)
      key = params.first.to_s

      # Check single records first
      if @records.dig(rpc_name, key)
        return [ @records[rpc_name][key] ]
      end

      # Check collections
      if @collections[rpc_name]
        return @collections[rpc_name]
      end

      # Check scalars
      if @scalars.dig(rpc_name, key)
        return @scalars[rpc_name][key]
      end

      ""
    end
  end
end
