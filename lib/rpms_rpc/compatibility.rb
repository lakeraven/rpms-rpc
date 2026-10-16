# frozen_string_literal: true

require "json"
require "set"
require_relative "core"

module RpmsRpc
  # The check a VistA client makes once at startup (rpms-rpc#366, ADR 0010 assertions 1 and 4):
  # which RPCs this release of the gem sends that the connected server does not serve. CPRS asks
  # the same question with XWB IS RPC AVAILABLE and ORWU VERSRV, because sites run different
  # patch levels.
  #
  #   report = client.compatibility           # after sign-on; reports, never raises for a gap
  #   report.ok?                              # => false
  #   report.missing                          # => { "RpmsRpc::Referral" => ["BMC ADD REFERRAL"] }
  #   client.compatibility(strict: true)      # raises MissingRpcsError naming them, for a host that
  #                                           #    wants to fail at boot
  #
  # What "this release needs" is REQUIRED_PATH: every RPC each public API module sends, written by
  # `rake rpc:required_rpcs` from the same static analysis the callable gate reads (ApiCoverage),
  # and held current by test/api_coverage/required_rpcs_test.rb. It is not a hand-kept list.
  #
  # How the server is asked is the broker client's (Client#served_rpcs): on CIA a paged DDR LISTER
  # of #8994 in the sign-on option (six calls for 5,557 entries), on XWB one XWB IS RPC AVAILABLE
  # per RPC. Neither runs the RPCs it asks about. "Served" is the server's registry: registered in REMOTE PROCEDURE (#8994) and not
  # inactive for a local client, which is what a call answers RpcNotAvailableError for. Whether
  # this user may run an RPC in a given option is a different question (RpcRefusedError), and not
  # this one.
  #
  # The check is advisory. Each API call still raises its own typed error when its RPC is missing
  # (#363); nothing here turns a missing RPC into empty data.
  module Compatibility
    REQUIRED_PATH = File.expand_path("required_rpcs.json", __dir__)

    # Raised by `compatibility(strict: true)` when the server lacks an RPC this release sends.
    class MissingRpcsError < Error
      attr_reader :report

      def initialize(report)
        @report = report
        super(report.to_s)
      end
    end

    # build    the rpms-ops build the gem's RPC list was derived against
    # required { API module => [RPC names] } this release sends
    # missing  the subset of required the server does not serve, same shape; modules with none
    #          are left out
    Report = Data.define(:build, :required, :missing) do
      def ok? = missing.empty?

      # Every missing RPC name once, sorted.
      def missing_rpcs = missing.values.flatten.uniq.sort

      def to_s
        return "the server serves every RPC this release of rpms-rpc sends (#{required_count} RPCs, derived on #{build})" if ok?

        lines = missing.map { |mod, names| "  #{mod}: #{names.join(', ')}" }
        "the server does not serve #{missing_rpcs.size} of the #{required_count} RPCs this release of rpms-rpc sends " \
          "(derived on #{build}):\n#{lines.join("\n")}"
      end

      private

      def required_count = required.values.flatten.uniq.size
    end

    module_function

    # The release's list: { "build" => tag, "modules" => { module => [RPC names] } }.
    def required(path = REQUIRED_PATH)
      JSON.parse(File.read(path))
    end

    # Ask `client` which of the required RPCs its server serves. The client must be signed on:
    # the check runs after sign-on, which it never changes.
    def check(client, strict: false, required: self.required)
      raise Client::AuthenticationError, "compatibility: sign on first; the check runs on a signed-on client" unless client.authenticated?

      modules = required.fetch("modules")
      served = client.served_rpcs(modules.values.flatten.uniq.sort)
      missing = modules.filter_map do |mod, names|
        absent = names.reject { |n| served.include?(n) }
        [ mod, absent ] unless absent.empty?
      end.to_h
      report = Report.new(build: required.fetch("build"), required: modules, missing: missing)
      raise MissingRpcsError, report if strict && !report.ok?

      report
    end
  end
end
