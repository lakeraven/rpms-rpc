# frozen_string_literal: true

require_relative "security_keys"
require_relative "user_roles"
require_relative "capabilities"

module RpmsRpc
  VERSION = "0.1.0"

  class NotConfiguredError < VistaRpc::NotConfiguredError; end

  class Configuration
    # `unsafe_raw_errors` opts out of PhiSanitizer scrubbing for
    # exception messages. Off by default — production deploys should
    # leave it off. Turn on only for development / offline forensic
    # captures where preserving raw broker payloads matters.
    attr_accessor :fhir_client, :unsafe_raw_errors

    def initialize
      @fhir_client = nil
      @unsafe_raw_errors = false
    end

    def client
      VistaRpc.configuration.client
    end

    def client=(client)
      VistaRpc.configuration.client = client
    end
  end

  class << self
    def configure
      yield(configuration)
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def client
      VistaRpc.client
    rescue VistaRpc::NotConfiguredError => e
      raise NotConfiguredError, e.message
    end

    def fhir_client
      configuration.fhir_client || raise(
        NotConfiguredError,
        "RpmsRpc.fhir_client is not configured. Call RpmsRpc.configure { |c| c.fhir_client = ... } " \
        "or RpmsRpc.mock_fhir! for testing."
      )
    end

    def reset!
      @configuration = Configuration.new
      VistaRpc.reset!
    end

    # Scrub PHI patterns from `message` before it propagates to a host
    # logger / exception handler. Used at exception-raise sites where
    # the gem interpolates raw broker response payloads. Honors the
    # `unsafe_raw_errors` flag.
    def sanitize_error(message)
      return "" if message.nil?
      return message.to_s if configuration.unsafe_raw_errors

      require_relative "phi_sanitizer"
      PhiSanitizer.sanitize_message(message.to_s)
    end

    # Convenience: configure a MockClient for testing.
    # Optionally accepts a block for seeding.
    def mock!
      require_relative "mock_client"
      mock = MockClient.new
      VistaRpc.configure { |c| c.client = mock }
      yield(mock) if block_given?
      mock
    end

    # Convenience: configure a MockFhirClient for testing.
    # Optionally accepts a block for seeding FHIR resources.
    def mock_fhir!
      require_relative "mock_fhir_client"
      mock = MockFhirClient.new
      configure { |c| c.fhir_client = mock }
      yield(mock) if block_given?
      mock
    end
  end
end
