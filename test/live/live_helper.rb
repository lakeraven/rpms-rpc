# frozen_string_literal: true

# Live specs (ADR 0009): Ruby tests that call the gem's real API over the wire
# against a fresh, disposable container of the pinned build. They assert shape
# and invariants, run once per persona, and are run by `rake test:live`, never
# by `rake test`.
#
# Env (all required; a spec FAILS without them, it never skips: a live spec
# is loaded only by `rake test:live` or by path, so a missing setting is a
# mistake, not an opt-out):
#   BROKER_HOST, BROKER_PORT   the broker of the target
#   RPMS_ACCESS, RPMS_VERIFY   the persona's sign-on pair (never logged)
#   PERSONA                    which user that is, e.g. PROV123 or SYS123
# The staging pair PROV123 also needs VISTA_RPC_ENV=development (Client's
# credential guard).
#
# Optional:
#   BROKER_PROTOCOL            cia (default) or xwb: the broker line spoken
#   LIVE_BUILD                 the target's build, when it is not the pin
#
# One broker line per run. A spec is written for one line and declares it
# (`broker :xwb`; undeclared is :cia). CIA specs live in test/live/, XWB specs
# in test/live/xwb/, and `rake test:live` loads only the directory of the
# run's BROKER_PROTOCOL, so a mixed suite never runs a spec on the wrong line.
# A spec loaded by path under the other protocol fails, naming the setting.
# Over CIA the harness signs on with CiaClient (CIANBRPC AUTH); over XWB with
# XwbClient#authenticate (XUS SIGNON SETUP, XUS AV CODE). A spec that proves
# sign-on itself declares `connect_only!`: the harness connects and leaves
# the session unauthenticated.
#
# No silent skips. Missing data, a refused RPC or an unreachable broker fails
# the spec with what is missing and what to do. The one acceptable skip is
# skip_tracked("#NNN", why), which names a tracked issue; the run's summary
# lists those by issue. A bare `skip` in a live spec fails the spec.
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
require "rpms_rpc/xwb_client"
require_relative "live_env"

module LiveSpec
  class Test < Minitest::Test
    class << self
      # Declare that this spec files data on the target.
      def writes! = (@writes = true)
      def writes? = @writes == true

      # Declare the broker line this spec is written for (:cia or :xwb).
      def broker(name = nil)
        @broker = name.to_s if name
        @broker || (superclass.respond_to?(:broker) ? superclass.broker : "cia")
      end

      # Declare that this spec signs on itself: connect, but do not sign on.
      def connect_only! = (@connect_only = true)
      def connect_only? = @connect_only == true
    end

    attr_reader :client

    def setup
      super
      missing = LiveSpec.missing_env
      flunk LiveSpec.missing_env_message(missing) unless missing.empty?
      error = LiveSpec.protocol_error
      flunk error if error
      unless self.class.broker == LiveSpec.protocol
        flunk "#{self.class} is written for the #{self.class.broker} broker and this run speaks " \
              "#{LiveSpec.protocol}: set BROKER_PROTOCOL=#{self.class.broker} and its broker's port"
      end
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

      @tracked_skip = true
      skip "#{issue}: #{why}"
    end

    # A bare skip fails: say what is missing and what to do, or name the issue.
    def skip(message = nil, _ignored = nil)
      flunk "bare skip in a live spec#{" (#{message})" if message}: fail with what is missing, or use skip_tracked(\"#NNN\", why)" unless @tracked_skip

      super
    end

    private

    BROKER_CLIENTS = { "cia" => RpmsRpc::CiaClient, "xwb" => RpmsRpc::XwbClient }.freeze

    def sign_on
      host = ENV.fetch("BROKER_HOST")
      port = ENV.fetch("BROKER_PORT")
      c = BROKER_CLIENTS.fetch(LiveSpec.protocol).new(host: host, port: Integer(port), timeout: 30)
      begin
        c.connect
      rescue RpmsRpc::Client::ConnectionError => e
        flunk "no broker answers at #{host}:#{port} (#{e.class.name.split('::').last}). " \
              "Start the container or the SSM tunnel, or fix BROKER_HOST/BROKER_PORT."
      end
      RpmsRpc.configure { |cfg| cfg.client = c }
      return c if self.class.connect_only?

      begin
        c.authenticate(ENV.fetch("RPMS_ACCESS"), ENV.fetch("RPMS_VERIFY"))
      rescue RpmsRpc::Client::CredentialError => e
        flunk "sign-on as #{persona} refused by the client's credential guard: #{e.message}. " \
              "A staging pair such as PROV123 needs VISTA_RPC_ENV=development."
      rescue RpmsRpc::Client::AuthenticationError => e
        flunk "sign-on as #{persona} refused at #{host}:#{port}: #{e.message}. " \
              "Check RPMS_ACCESS/RPMS_VERIFY are #{persona}'s pair on that build."
      end
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
      io.puts format("%-9s %s", "backend", "#{@env['BROKER_HOST']}:#{@env['BROKER_PORT']} (#{LiveSpec.protocol(@env)})")
      io.puts format("%-9s %s", "build", LiveSpec.build_label(@env))
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
