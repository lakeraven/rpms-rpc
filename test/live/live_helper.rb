# frozen_string_literal: true

# Live specs (ADR 0009): Ruby tests that call the gem's real API over the wire
# against a fresh, disposable container of the pinned build. They assert shape
# and invariants, run once per persona, and are run by `rake test:live`, never
# by `rake test`.
#
# Env (all required; a spec FAILS without them, it never skips: a live spec
# is loaded only by `rake test:live` or by path, so a missing setting is a
# mistake, not an opt-out):
#   BROKER_HOST, BROKER_PORT   the CIA broker of the target
#   RPMS_ACCESS, RPMS_VERIFY   the persona's sign-on pair (never logged)
#   PERSONA                    which user that is, e.g. PROV123 or SYS123
# The staging pair PROV123 also needs VISTA_RPC_ENV=development (Client's
# credential guard).
#
# No silent skips. Missing data, a refused RPC or an unreachable broker fails
# the spec with what is missing and what to do. The one acceptable skip is
# skip_tracked("#NNN", why), which names a tracked issue; the run's summary
# lists those by issue. test/rpms_rpc/fake_freeze_test.rb fails on a bare skip.
#
# A spec that WRITES declares `writes!`. It runs only when the target is
# declared disposable (LIVE_DISPOSABLE=1) and is on this machine (a loopback
# BROKER_HOST); anything else fails the spec, so a write can never reach a
# shared stack by a mistyped env.
#
# The run ends in one summary block (LiveSpec::Summary): backend, build,
# persona, counts, skips by issue. Under `rake test:live` (LIVE_RUN=1) a run in
# which no live spec ran is a failure.
require "minitest/autorun"
require "rpms_rpc/mappings"
require "rpms_rpc/cia_client"
require_relative "live_env"

module LiveSpec
  class Test < Minitest::Test
    class << self
      # Declare that this spec files data on the target.
      def writes! = (@writes = true)
      def writes? = @writes == true
    end

    attr_reader :client

    def setup
      super
      missing = LiveSpec.missing_env
      flunk LiveSpec.missing_env_message(missing) unless missing.empty?
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

    # The one acceptable skip: it names the tracked issue that will make the
    # spec runnable, and the summary counts it under that issue.
    def skip_tracked(issue, why)
      flunk "skip_tracked(#{issue.inspect}, ...) names no issue: pass \"#NNN\", or fail the spec instead" unless issue.to_s.match?(/\A#\d+\z/)

      skip "#{issue}: #{why}"
    end

    private

    def sign_on
      host = ENV.fetch("BROKER_HOST")
      port = ENV.fetch("BROKER_PORT")
      c = RpmsRpc::CiaClient.new(host: host, port: Integer(port), timeout: 30)
      begin
        c.connect
      rescue RpmsRpc::Client::ConnectionError => e
        flunk "no broker answers at #{host}:#{port} (#{e.class.name.split('::').last}). " \
              "Start the container or the SSM tunnel, or fix BROKER_HOST/BROKER_PORT."
      end
      begin
        c.authenticate(ENV.fetch("RPMS_ACCESS"), ENV.fetch("RPMS_VERIFY"))
      rescue RpmsRpc::Client::CredentialError => e
        flunk "sign-on as #{persona} refused by the client's credential guard: #{e.message}. " \
              "A staging pair such as PROV123 needs VISTA_RPC_ENV=development."
      rescue RpmsRpc::Client::AuthenticationError => e
        flunk "sign-on as #{persona} refused at #{host}:#{port}: #{e.message}. " \
              "Check RPMS_ACCESS/RPMS_VERIFY are #{persona}'s pair on that build."
      end
      RpmsRpc.configure { |cfg| cfg.client = c }
      c
    end
  end

  # The end-of-run block. Counts live specs only, so a plain `rake test` that
  # loads this helper (the guard test) prints nothing.
  class Summary < Minitest::StatisticsReporter
    def initialize(io = $stdout, env: ENV)
      super(io)
      @env = env
    end

    def record(result)
      super if LiveSpec.live_result?(result)
    end

    def live_run? = @env["LIVE_RUN"] == "1"
    def none_ran? = (count - skips).zero?

    def passed?
      super && !(live_run? && none_ran?)
    end

    def report
      super
      return unless live_run? || count.positive?

      io.puts
      io.puts "== live run " + ("=" * 56)
      io.puts format("%-9s %s", "backend", "#{@env['BROKER_HOST']}:#{@env['BROKER_PORT']}")
      io.puts format("%-9s %s", "build", LiveSpec.build_label)
      io.puts format("%-9s %s", "persona", @env["PERSONA"])
      io.puts format("%-9s %d runs, %d assertions, %d failures, %d errors, %d skips",
                     "result", count, assertions, failures, errors, skips)
      skipped_by_issue.each do |issue, tests|
        io.puts format("  SKIPPED %-6s %3d  %s", issue, tests.size, tests.join(", "))
      end
      io.puts "NOT GREEN: no live spec ran" if none_ran?
      io.puts "=" * 68
    end

    private

    def skipped_by_issue
      results.select(&:skipped?).group_by { |r| r.failure.message[/\A#\d+/] || "(none)" }
             .transform_values { |rs| rs.map { |r| "#{r.klass}##{r.name}" } }
    end
  end

  def self.live_result?(result)
    klass = Object.const_get(result.klass)
    klass.is_a?(Class) && klass < LiveSpec::Test
  rescue NameError
    false
  end
end

module Minitest
  def self.plugin_live_summary_init(options)
    reporter << LiveSpec::Summary.new(options[:io])
  end
end
Minitest.extensions << "live_summary" unless Minitest.extensions.include?("live_summary")
