# frozen_string_literal: true

module RpmsRpc
  # Mock FHIR client for testing. Reads from the same seed data as MockClient
  # and returns FHIR R4-shaped hashes. No HTTP, no external dependencies.
  #
  # Consumers seed FHIR resources directly:
  #
  #   RpmsRpc.mock_fhir! do |f|
  #     f.seed_resource("Patient", "1", {
  #       resourceType: "Patient", id: "1",
  #       name: [{ family: "Anderson", given: ["Alice"] }],
  #       gender: "female", birthDate: "1980-05-15"
  #     })
  #   end
  #
  #   RpmsRpc.fhir_client.read("Patient", "1")
  #   RpmsRpc.fhir_client.search("Patient", name: "Anderson")
  #
  class MockFhirClient
    def initialize
      @resources = {} # { "Patient" => { "1" => { resourceType: "Patient", ... } } }
    end

    # Seed a single FHIR resource.
    def seed_resource(resource_type, id, resource_hash)
      @resources[resource_type] ||= {}
      @resources[resource_type][id.to_s] = resource_hash.is_a?(Hash) ? resource_hash : resource_hash.to_h
    end

    # Read a single resource by type and ID.
    def read(resource_type, id)
      resource = @resources.dig(resource_type, id.to_s)
      return operation_outcome("not-found", "#{resource_type}/#{id} not found") unless resource

      stringify_keys_deep(resource)
    end

    # Search resources by type and params.
    # Supports: name (prefix match on family/given), identifier, patient, _id
    def search(resource_type, params = {})
      candidates = @resources[resource_type]&.values || []
      results = filter(candidates, params)
      bundle(results)
    end

    private

    def filter(resources, params)
      resources.select do |r|
        params.all? { |key, value| matches?(r, key.to_s, value.to_s) }
      end
    end

    def matches?(resource, key, value)
      case key
      when "name"
        match_name(resource, value)
      when "identifier"
        match_identifier(resource, value)
      when "patient"
        match_patient(resource, value)
      when "_id"
        resource[:id].to_s == value || resource["id"].to_s == value
      when "gender"
        (resource[:gender] || resource["gender"]).to_s == value
      when "birthdate"
        (resource[:birthDate] || resource["birthDate"]).to_s == value
      else
        true # unknown params don't filter
      end
    end

    def match_name(resource, value)
      names = resource[:name] || resource["name"] || []
      names.any? do |n|
        family = (n[:family] || n["family"]).to_s
        given = Array(n[:given] || n["given"]).join(" ")
        full = "#{family} #{given}"
        full.upcase.include?(value.upcase) || family.upcase.start_with?(value.upcase)
      end
    end

    def match_identifier(resource, value)
      identifiers = resource[:identifier] || resource["identifier"] || []
      identifiers.any? { |i| (i[:value] || i["value"]).to_s == value }
    end

    def match_patient(resource, value)
      subject = resource[:subject] || resource["subject"] || {}
      ref = (subject[:reference] || subject["reference"]).to_s
      ref == "Patient/#{value}" || ref == value
    end

    def bundle(entries)
      {
        "resourceType" => "Bundle",
        "type" => "searchset",
        "total" => entries.length,
        "entry" => entries.map { |e| { "resource" => stringify_keys_deep(e) } }
      }
    end

    def operation_outcome(code, message)
      {
        "resourceType" => "OperationOutcome",
        "issue" => [{ "severity" => "error", "code" => code, "diagnostics" => message }]
      }
    end

    def stringify_keys_deep(obj)
      case obj
      when Hash then obj.transform_keys(&:to_s).transform_values { |v| stringify_keys_deep(v) }
      when Array then obj.map { |v| stringify_keys_deep(v) }
      else obj
      end
    end
  end
end
