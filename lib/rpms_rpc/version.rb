# frozen_string_literal: true

module RpmsRpc
  VERSION = "0.1.0"

  class NotConfiguredError < StandardError; end

  class Configuration
    attr_accessor :client
  end

  class << self
    def configure
      yield(configuration)
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def client
      configuration.client || raise(
        NotConfiguredError,
        "RpmsRpc.client is not configured. Call RpmsRpc.configure { |c| c.client = ... } " \
        "or RpmsRpc.mock! for testing."
      )
    end

    def reset!
      @configuration = Configuration.new
    end

    # Convenience: configure a MockClient for testing.
    # Optionally accepts a block for seeding.
    def mock!
      require_relative "mock_client"
      mock = MockClient.new
      configure { |c| c.client = mock }
      yield(mock) if block_given?
      mock
    end
  end
end
