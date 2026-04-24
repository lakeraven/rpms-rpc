# frozen_string_literal: true

module RpmsRpc
  # FHIR client interface for reading RPMS data via FHIR R4 API.
  # In production, this wraps HTTP calls to an IRIS for Health FHIR endpoint.
  # In test, MockFhirClient returns FHIR-shaped JSON from seeded data.
  #
  #   # Search
  #   RpmsRpc.fhir_client.search("Patient", name: "Anderson")
  #   # => { "resourceType" => "Bundle", "type" => "searchset", ... }
  #
  #   # Read
  #   RpmsRpc.fhir_client.read("Patient", "1")
  #   # => { "resourceType" => "Patient", "id" => "1", ... }
  #
  class FhirClient
    attr_reader :base_url

    def initialize(base_url:)
      @base_url = base_url
    end

    def search(resource_type, params = {})
      query = params.map { |k, v| "#{k}=#{v}" }.join("&")
      url = "#{@base_url}/#{resource_type}?#{query}"
      response = Net::HTTP.get(URI(url))
      JSON.parse(response)
    end

    def read(resource_type, id)
      url = "#{@base_url}/#{resource_type}/#{id}"
      response = Net::HTTP.get(URI(url))
      JSON.parse(response)
    end
  end
end
