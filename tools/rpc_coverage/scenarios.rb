# frozen_string_literal: true

require "json"
require "yaml"

# Coverage per pilot scenario, as the test role that plays its persona (rpms-rpc#818).
#
# A live spec declares the openrpms-ux scenarios it proves (`proves "S-SCH-01.1"`, test/live/live_helper.rb),
# and `rake test:live` writes, per role, a summary listing every spec it ran with its result and the RPCs it
# sent (coverage/live/<role>.json, "specs"). For each scenario of a pilot story (data/rpc_coverage/pilot.yml):
#   proven  every spec that declares it ran as the story's role and passed, and it sent at least one RPC
#   short   otherwise, with why: no spec declares it as that role, there is no live run as that role, a spec
#           failed, a spec was skipped by a tracked issue (`needs "<option>", tracked:`: the role's row does
#           not hold the option), or it sent no RPC
# Each scenario lists its calls: the RPC, its outcome (answered, refused, error) and whether a passing spec
# as the role sent it. The operator's summary is never read for a scenario: XUPROGMODE answers under every
# option, so its answers prove nothing about a role's permissions.
#
# Lives under tools/ so it never ships in the gem.
module RpcCoverage
  module Scenarios
    OPERATOR = "operator"
    STORY = /\AS-[A-Z]+-\d+/

    Row = Struct.new(:id, :role, :status, :why, :specs, :calls, keyword_init: true) do
      def proven? = status == "proven"
    end

    Report = Struct.new(:rows, :stories, :undeclared, :builds, :answered, keyword_init: true) do
      def proven = rows.count(&:proven?)

      def headline
        "pilot scenarios whose calls are all proven live as their role: #{proven} of #{rows.size} " \
          "(the scenarios live specs declare, in #{stories.size} pilot stories)"
      end

      def lines
        out = [ headline ]
        out << "  live runs: #{builds.empty? ? 'none' : builds.map { |r, b| "#{r} on #{b}" }.join(', ')}"
        rows.each do |r|
          out << format("  %-12s %-17s %-7s %s", r.id, r.role, r.status, r.why)
          r.calls.each { |c| out << format("      %-32s %-9s %s", c["rpc"], c["outcome"], c["proven"] ? "proven" : "not proven") }
        end
        out << "  pilot stories with no scenario a live spec declares: #{undeclared.join(', ')}" unless undeclared.empty?
        out
      end

      def to_h
        { headline: headline, proven: proven, scenarios: rows.size, builds: builds, undeclared_stories: undeclared,
          rows: rows.map { |r| r.to_h.merge(specs: r.specs) } }
      end
    end

    module_function

    # { "S-REG-01" => "front_desk_clerk", ... }
    def load_pilot(path)
      stories = (YAML.safe_load_file(path) || {})["stories"]
      raise ArgumentError, "#{path}: stories must map a story id to a test role" unless stories.is_a?(Hash) && !stories.empty?

      stories.transform_keys(&:to_s).transform_values(&:to_s)
    end

    # { role => { "build" => tag, "specs" => [...] } } from every live summary under DIR (any depth: a
    # directory of CI artifacts holds one per role). A role run on several broker lines merges its specs.
    # A summary with no "specs" (written before #818, or a pending marker) adds none.
    def load_summaries(dir)
      Dir[File.join(dir, "**", "*.json")].sort.each_with_object({}) do |path, by_role|
        doc = JSON.parse(File.read(path))
        next unless doc.is_a?(Hash) && doc["role"].is_a?(String) && doc["specs"].is_a?(Array)

        entry = (by_role[doc["role"]] ||= { "build" => doc["build"], "specs" => [] })
        entry["specs"] += doc["specs"]
      rescue JSON::ParserError
        next
      end
    end

    # plan: { spec file => { roles: [Symbol], scenarios: [id] } } (LiveSpec.scenario_plan).
    def report(pilot:, plan:, summaries:)
      declared = plan.flat_map { |_, d| d[:scenarios] }.uniq.select { |id| pilot.key?(id[STORY]) }.sort_by { |id| sort_key(id) }
      rows = declared.map { |id| row(id, pilot.fetch(id[STORY]), plan, summaries) }
      undeclared = pilot.keys.reject { |story| declared.any? { |id| id[STORY] == story } }
      Report.new(rows: rows, stories: pilot.keys, undeclared: undeclared,
                 builds: summaries.transform_values { |s| s["build"] }.sort.to_h, answered: answered(summaries))
    end

    def sort_key(id) = id.scan(/\d+|[A-Z]+/).map { |p| p.match?(/\d/) ? p.to_i : p }

    def row(id, role, plan, summaries)
      files = plan.select { |_, d| d[:scenarios].include?(id) }
      mine = files.select { |_, d| d[:roles].map(&:to_s).include?(role) }
      base = { id: id, role: role, specs: [], calls: [] }
      return Row.new(**base, status: "short", why: "declared only as #{other_roles(files)} (#{files.keys.join(', ')}), not as #{role}") if mine.empty?

      run = summaries[role]
      return Row.new(**base, status: "short", why: "no live run as #{role} recorded its specs (rake test:live ROLE=#{role})") unless run

      results = run["specs"].select { |s| Array(s["proves"]).include?(id) }
      return Row.new(**base, status: "short", why: "no spec that declares it ran as #{role}") if results.empty?

      calls = merge_calls(results)
      specs = results.map { |s| { spec: s["spec"], result: s["result"] } }
      Row.new(id: id, role: role, specs: specs, calls: calls, **verdict(results, calls))
    end

    def other_roles(files) = files.values.flat_map { |d| d[:roles] }.uniq.join(", ").then { |s| s.empty? ? "no role" : s }

    # Each distinct call with its outcome, proven when a passing spec sent it.
    def merge_calls(results)
      results.each_with_object({}) do |s, acc|
        Array(s["calls"]).each do |c|
          key = [ c["rpc"], c["outcome"] ]
          e = (acc[key] ||= { "rpc" => c["rpc"], "outcome" => c["outcome"], "proven" => false })
          e["detail"] ||= c["detail"] if c["detail"]
          e["proven"] ||= s["result"] == "pass"
        end
      end.values.sort_by { |c| [ c["rpc"], c["outcome"] ] }
    end

    def verdict(results, calls)
      bad = results.reject { |s| s["result"] == "pass" }
      unless bad.empty?
        s = bad.first
        why = s["result"] == "skip" ? "#{s['spec']} skipped: #{s['skip']}" : "#{s['spec']} #{s['result'] == 'error' ? 'errored' : 'failed'}"
        return { status: "short", why: why + (bad.size > 1 ? " (and #{bad.size - 1} more)" : "") }
      end
      return { status: "short", why: "its specs passed but sent no RPC" } if calls.empty?

      { status: "proven", why: "#{results.size} spec(s) passed; #{calls.size} call(s), all proven" }
    end

    # { rpc => [roles that got it answered] } from every summary.
    def answered(summaries)
      summaries.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(role, s), acc|
        s["specs"].each do |spec|
          Array(spec["calls"]).each { |c| acc[c["rpc"]] |= [ role ] if c["outcome"] == "answered" }
        end
      end
    end

    # The registered RPCs a role other than the operator got answered, and those only the operator did.
    def rpc_counts(report, registry_names)
      known = registry_names.to_h { |n| [ n, true ] }
      by_role = report.answered.select { |rpc, _| known[rpc] }
      roles = by_role.count { |_, rs| (rs - [ OPERATOR ]).any? }
      { roles: roles, operator_only: by_role.count { |_, rs| rs == [ OPERATOR ] }, registered: registry_names.size }
    end
  end
end
