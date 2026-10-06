# frozen_string_literal: true

require "monitor"
require_relative "version"

# Core module state: configuration, the wire lock, and error sanitizing.
# Deliberately dependency-free beyond stdlib so a consumer can require a single
# client file (rpms_rpc/cia_client) without pulling in the mappings,
# capabilities and role tables. Anything heavier belongs in the entry point,
# lib/rpms_rpc.rb, which requires this and adds the aggregate surface.
module RpmsRpc
  # Process-wide fallback wire lock. Used ONLY when the configured client does
  # not define its own #synchronize_wire — see RpmsRpc.synchronize_wire. A
  # client that cannot serialize its own wire must still be serialized coarsely
  # rather than run unlocked.
  MODULE_WIRE_LOCK = Monitor.new

  # The base class of every exception the gem raises (ADR 0010, assertion 4;
  # #357): a host rescues RpmsRpc::Error in one place and tells the failures
  # apart by subclass. Every other error class in lib/ descends from it; the
  # names and the relationships between them (CredentialError <
  # AuthenticationError, RpcTimeoutError < TimeoutError < ConnectionError, ...)
  # are unchanged, so existing rescues keep working.
  class Error < StandardError; end

  class NotConfiguredError < Error; end

  class Configuration
    # `unsafe_raw_errors` opts out of PhiSanitizer scrubbing for
    # exception messages. Off by default — production deploys should
    # leave it off. Turn on only for development / offline forensic
    # captures where preserving raw broker payloads matters.
    attr_accessor :client, :fhir_client, :unsafe_raw_errors

    def initialize
      @client = nil
      @fhir_client = nil
      @unsafe_raw_errors = false
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
      configuration.client || raise(
        NotConfiguredError,
        "RpmsRpc.client is not configured. Call RpmsRpc.configure { |c| c.client = ... } " \
        "or RpmsRpc.mock! for testing."
      )
    end

    # DEPRECATED (#360): a FHIR client is host knowledge (ADR 0010, assertion 7).
    # Every call warns; the method and FhirClient go in a later release.
    def fhir_client
      warn_fhir_client_deprecated("RpmsRpc.fhir_client", uplevel: 2)
      configuration.fhir_client || raise(
        NotConfiguredError,
        "RpmsRpc.fhir_client is not configured. Call RpmsRpc.configure { |c| c.fhir_client = ... } " \
        "or RpmsRpc.mock_fhir! for testing."
      )
    end

    def reset!
      @configuration = Configuration.new
    end

    # One wording for both deprecated entry points, so a host reading its log
    # sees the same notice from either. `uplevel` points the warning at the
    # host's call site, not at the gem.
    def warn_fhir_client_deprecated(name, uplevel:)
      warn "[rpms_rpc] DEPRECATED: #{name} is leaving the gem (#360): a FHIR client is host " \
           "knowledge (ADR 0010, assertion 7). Keep a copy in the host; it will be removed in a later release.",
           uplevel: uplevel
    end

    # Run `block` with exclusive use of the shared broker client.
    #
    # `RpmsRpc.client` is ONE process-global object over a bare
    # request/response socket with no per-message correlation id, so two
    # threads calling through it can consume each other's replies. Any caller
    # whose correctness spans more than one RPC — above all sign-on, which
    # reads back the identity everything downstream is authorized as — must
    # hold this lock for the whole sequence.
    #
    # Reentrant: nested synchronize_wire calls (and the per-call locking the
    # transports do internally) do not deadlock.
    #
    # FAIL CLOSED. A client that does not define #synchronize_wire (a wrapper
    # or delegator that only forwards the RPC surface) is NOT yielded to
    # unlocked: post-0.3.0 this module method always exists, so a consumer's
    # `respond_to?(:synchronize_wire)` guard is vacuously true and its own
    # fallback lock is dead code — yielding unlocked here would then be a
    # SILENT miss, weaker than the pre-0.3.0 world where the absence was
    # visible. Fall back to a process-wide lock so a non-conforming client is
    # still serialized.
    def synchronize_wire(&block)
      c = client
      return c.synchronize_wire(&block) if c.respond_to?(:synchronize_wire)

      MODULE_WIRE_LOCK.synchronize(&block)
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
      configure { |c| c.client = mock }
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
