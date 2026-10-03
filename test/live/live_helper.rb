# frozen_string_literal: true

# Live specs (ADR 0009): Ruby tests that call the gem's real API over the wire
# against a fresh, disposable container of the pinned build. They assert shape
# and invariants, run once per persona, and are run by `rake test:live`, never
# by `rake test`.
#
# Env (all required, or every live spec skips):
#   BROKER_HOST, BROKER_PORT   the broker of the target (CIA unless BROKER_PROTOCOL says)
#   RPMS_ACCESS, RPMS_VERIFY   the persona's sign-on pair (never logged)
#   PERSONA                    which user that is, e.g. PROV123 or SYS123
# The staging pair PROV123 also needs VISTA_RPC_ENV=development (Client's
# credential guard).
#
# BROKER_PROTOCOL (optional, default cia; or xwb) names the broker at
# BROKER_HOST:BROKER_PORT. A spec declares the broker it speaks with
# `broker :xwb` (default :cia) and is skipped, saying so, against any other;
# run `rake test:live` once per broker the build serves. An unknown
# BROKER_PROTOCOL fails every spec.
#
# A spec that WRITES declares `writes!`. It runs only when the target is
# declared disposable (LIVE_DISPOSABLE=1) and is on this machine (a loopback
# BROKER_HOST); anything else fails the spec instead of skipping it, so a write
# can never reach a shared stack by a mistyped env.
require "minitest/autorun"
require "rpms_rpc/mappings"
require "rpms_rpc/cia_client"
require "rpms_rpc/xwb_client"

module LiveSpec
  REQUIRED_ENV = %w[BROKER_HOST BROKER_PORT RPMS_ACCESS RPMS_VERIFY PERSONA].freeze
  LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1].freeze
  CLIENTS = { cia: RpmsRpc::CiaClient, xwb: RpmsRpc::XwbClient }.freeze

  module_function

  # The broker protocol the env targets, or nil when BROKER_PROTOCOL names none we speak.
  def target_broker(env = ENV)
    name = env["BROKER_PROTOCOL"].to_s.strip.downcase
    name = "cia" if name.empty?
    CLIENTS.key?(name.to_sym) ? name.to_sym : nil
  end

  # The names of the required variables that are unset or blank.
  def missing_env(env = ENV)
    REQUIRED_ENV.select { |k| env[k].to_s.strip.empty? }
  end

  # nil when a writing spec may run against this env, else the reason it may not.
  def write_refusal(env = ENV)
    return "LIVE_DISPOSABLE=1 is not set: the target is not declared disposable" unless env["LIVE_DISPOSABLE"] == "1"
    return "BROKER_HOST #{env['BROKER_HOST'].inspect} is not loopback: writes go only to a local container" unless LOOPBACK_HOSTS.include?(env["BROKER_HOST"].to_s)

    nil
  end

  class Test < Minitest::Test
    class << self
      # Declare that this spec files data on the target.
      def writes! = (@writes = true)
      def writes? = @writes == true

      # Declare (or read) the broker this spec speaks: :cia (default) or :xwb.
      def broker(protocol = nil)
        return @broker || :cia if protocol.nil?
        raise ArgumentError, "unknown broker #{protocol.inspect}" unless CLIENTS.key?(protocol)

        @broker = protocol
      end
    end

    attr_reader :client

    def setup
      super
      missing = LiveSpec.missing_env
      skip "live spec: set #{missing.join(', ')} to run against a broker" unless missing.empty?
      target = LiveSpec.target_broker
      flunk "live spec: BROKER_PROTOCOL #{ENV['BROKER_PROTOCOL'].inspect} is not one of #{CLIENTS.keys.join(', ')}" unless target
      skip "live spec speaks #{self.class.broker}; the target is #{target} (BROKER_PROTOCOL)" unless target == self.class.broker
      if self.class.writes? && (reason = LiveSpec.write_refusal)
        flunk "live spec writes, refused: #{reason}"
      end
      @client = sign_on
    end

    def teardown
      @client&.disconnect
      RpmsRpc.reset!
      super
    end

    def persona = ENV.fetch("PERSONA")

    private

    def sign_on
      c = CLIENTS.fetch(self.class.broker).new(host: ENV.fetch("BROKER_HOST"), port: Integer(ENV.fetch("BROKER_PORT")), timeout: 30)
      c.connect
      c.authenticate(ENV.fetch("RPMS_ACCESS"), ENV.fetch("RPMS_VERIFY"))
      RpmsRpc.configure { |cfg| cfg.client = c }
      c
    end
  end
end
