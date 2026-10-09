# frozen_string_literal: true

require_relative "core"

module RpmsRpc
  # DEPRECATED (#360): a FHIR client is host knowledge (ADR 0010, assertion 7)
  # and leaves the gem in a later release. Instantiating one warns; a host that
  # uses it should carry its own copy before then.
  #
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
      RpmsRpc.warn_fhir_client_deprecated("RpmsRpc::FhirClient", uplevel: 2)
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
