# frozen_string_literal: true

require "json"
require "yaml"

# RPC coverage: how much of ONE backend's registered RPC surface rpms-rpc has shown working
# against that backend (rpms-rpc#270). Offline; `rake rpc:coverage` drives it.
#
#   denominator  every #8994 NAME in the pinned registry (data/rpc_coverage/registry/<tag>.txt),
#                minus the names data/rpc_coverage/exclusions.yml excludes with a reason
#   covered      registered, not excluded, and a live run against the backend
#                (data/rpc_coverage/live/<backend>.json, written by `rake rpc:live`) got an answer
#                that was not a broker error (data, or an empty reply)
#
# Mock-driven unit tests do not count: MockClient answers any name it is seeded with, including
# names no RPMS registers (#207, #255). Coverage here means "a real server answered".
#
# Lives under tools/ so it never ships in the gem (spec.files lists bin, data allowlists, lib, docs).
module RpcCoverage
  # #8994 NAME is a 30-character free-text field (^DD(8994,.01,0)); a longer name is not a
  # registry entry.
  NAME_MAX = 30
  EXCLUSION_REASONS = {
    "no_routine_on_image" => "registered, but the routine it names is not on the backend image",
    "gui_plumbing" => "drives a thick-client GUI (layout, window state); no headless use (ADR-0004 tiers)",
    "write_needs_fixture" => "a write or side effect that needs a disposable fixture before it can run live"
  }.freeze
  STATUSES = %w[covered live_error declared_untested not_declared].freeze
  EVIDENCE_KEYS = %w[backend runs rpcs].freeze
  RUN_KEYS = %w[at rpms_rpc host_label context cases tally signons].freeze
  RPC_KEYS = %w[outcome error last_at].freeze

  class Error < StandardError; end

  Registry = Struct.new(:path, :tag, :names, :header, keyword_init: true)

  module_function

  # --- inputs ---------------------------------------------------------------------------------

  def load_registry(path)
    raise Error, "registry not found: #{path}" unless File.exist?(path)

    header = []
    names = []
    File.readlines(path, chomp: true).each do |l|
      next if l.strip.empty?

      l.start_with?("#") ? header << l : names << l
    end
    Registry.new(path: path, tag: File.basename(path, ".txt"), names: names, header: header)
  end

  def registry_problems(registry)
    problems = []
    problems << "registry #{registry.path} has no names" if registry.names.empty?
    dups = registry.names.tally.select { |_, n| n > 1 }.keys
    problems << "registry has duplicate names: #{dups.first(5).join(', ')}" unless dups.empty?
    long = registry.names.select { |n| n.length > NAME_MAX }
    problems << "registry has names over #{NAME_MAX} chars (not a #8994 dump?): #{long.first(3).join(', ')}" unless long.empty?
    problems
  end

  def load_exclusions(path)
    return {} unless path && File.exist?(path)

    data = YAML.safe_load_file(path) || {}
    raise Error, "#{path} must map RPC name => reason" unless data.is_a?(Hash)

    data.transform_keys(&:to_s).transform_values(&:to_s)
  end

  def exclusion_problems(exclusions, registry)
    known = registry.names.to_h { |n| [ n, true ] }
    exclusions.flat_map do |name, reason|
      out = []
      out << "exclusion #{name.inspect} is not registered on #{registry.tag}" unless known[name]
      out << "exclusion #{name.inspect} has unknown reason #{reason.inspect} (allowed: #{EXCLUSION_REASONS.keys.join(', ')})" unless EXCLUSION_REASONS.key?(reason)
      out
    end
  end

  def empty_evidence(backend)
    { "backend" => backend, "runs" => [], "rpcs" => {} }
  end

  def load_evidence(path, backend)
    return empty_evidence(backend) unless path && File.exist?(path)

    JSON.parse(File.read(path))
  end

  # Evidence is committed, so it must never carry a sign-on credential. The schema is closed
  # (no key can smuggle one in), and when the codes are in the environment the whole file is
  # searched for them.
  def evidence_problems(evidence, secrets: [])
    problems = []
    extra = evidence.keys - EVIDENCE_KEYS
    problems << "live evidence has unexpected keys: #{extra.join(', ')}" unless extra.empty?
    Array(evidence["runs"]).each_with_index do |run, i|
      bad = run.keys - RUN_KEYS
      problems << "live evidence run #{i} has unexpected keys: #{bad.join(', ')}" unless bad.empty?
    end
    (evidence["rpcs"] || {}).each do |name, e|
      bad = e.keys - RPC_KEYS
      problems << "live evidence for #{name} has unexpected keys: #{bad.join(', ')}" unless bad.empty?
      problems << "live evidence for #{name} has outcome #{e['outcome'].inspect}" unless %w[ok error].include?(e["outcome"])
    end
    text = JSON.generate(evidence)
    problems << "live evidence contains a sign-on code" if secrets.compact.reject(&:empty?).any? { |s| text.include?(s) }
    problems
  end

  # Names rpms-rpc declares: `m.rpc "NAME"` in lib/rpms_rpc/mappings, plus quoted RPC-shaped
  # strings elsewhere in lib/ on a line whose CODE (string literals blanked, so a message that
  # merely mentions "RPC" does not count) sends or registers an RPC, or that builds a CIA RPC
  # frame (`pk("RPC")`, cia_client.rb), or inside a capability-probe register([...]) block.
  RPC_STRING = /"([A-Z][A-Z0-9%]+(?: [A-Z0-9?\/&()%.-]+)+)"/
  RPC_LINE = /call_rpc|_rpc\(|\brpc\b|rpcs?\s*=/i
  CIA_FRAME = /pk\("RPC"\)/

  def declared_names(root)
    sites = Hash.new { |h, k| h[k] = [] }
    Dir[File.join(root, "lib/rpms_rpc/mappings/*.rb")].each do |f|
      File.readlines(f).each_with_index do |l, i|
        sites[Regexp.last_match(1)] << "#{rel(f, root)}:#{i + 1}" if l =~ /^\s*m\.rpc\s+"([^"]+)"/
      end
    end
    Dir[File.join(root, "lib/**/*.rb")].each do |f|
      next if f.include?("/mappings/") || f.end_with?("/mock_client.rb")

      in_register = false
      File.readlines(f).each_with_index do |l, i|
        code = l.sub(/\s#.*$/, "")
        next if code.strip.start_with?("#")

        in_register = true if code.match?(/\bregister\(/)
        sends = code.gsub(/"[^"]*"/, '""').match?(RPC_LINE) || code.match?(CIA_FRAME)
        code.scan(RPC_STRING) { |(n)| sites[n] << "#{rel(f, root)}:#{i + 1}" } if in_register || sends
        in_register = false if in_register && code.include?("])")
      end
    end
    sites
  end

  def rel(path, root) = path.delete_prefix("#{File.expand_path(root)}/").delete_prefix("#{root}/")

  # --- the report -----------------------------------------------------------------------------

  Report = Struct.new(:registry, :backend, :rows, :counts, :covered, :denominator, :excluded,
                      :declared_registered, :unregistered_used, :percent, keyword_init: true) do
    def one_liner
      "RPC coverage: #{format('%.1f', percent)}% (#{covered} / #{denominator} registered on #{registry.tag}; " \
        "#{excluded} excluded) · declared #{declared_registered} · unregistered names used #{unregistered_used.size}"
    end

    def status_lines
      order = RpcCoverage::STATUSES + counts.keys.grep(/\Aexcluded:/).sort
      order.map { |s| format("  %-22s %5d", s, counts.fetch(s, 0)) }
    end

    def tsv
      head = [
        "# #{one_liner}",
        "# backend: #{backend}",
        "# #{counts.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}",
        "name\tstatus\tdetail"
      ]
      (head + rows.map { |r| [ r[:name], r[:status], r[:detail] ].join("\t") }).join("\n") + "\n"
    end

    def to_h
      { backend: backend, registry: registry.tag, percent: percent.round(2), covered: covered,
        denominator: denominator, excluded: excluded, declared_registered: declared_registered,
        unregistered_used: unregistered_used, counts: counts }
    end
  end

  def compute(registry:, declared:, evidence:, exclusions:, backend:)
    live = evidence["rpcs"] || {}
    rows = registry.names.map do |name|
      e = live[name]
      if (reason = exclusions[name])
        { name: name, status: "excluded:#{reason}", detail: "" }
      elsif e && e["outcome"] == "ok"
        { name: name, status: "covered", detail: "" }
      elsif e
        { name: name, status: "live_error", detail: e["error"].to_s.tr("\t\n", "  ") }
      elsif declared.key?(name)
        { name: name, status: "declared_untested", detail: declared[name].first.to_s }
      else
        { name: name, status: "not_declared", detail: "" }
      end
    end
    counts = rows.map { |r| r[:status] }.tally
    excluded = rows.count { |r| r[:status].start_with?("excluded:") }
    denominator = registry.names.size - excluded
    covered = counts.fetch("covered", 0)
    known = registry.names.to_h { |n| [ n, true ] }
    used = (declared.keys + live.keys).uniq
    Report.new(
      registry: registry, backend: backend, rows: rows, counts: counts, covered: covered,
      denominator: denominator, excluded: excluded,
      declared_registered: declared.keys.count { |n| known[n] },
      unregistered_used: used.reject { |n| known[n] }.sort,
      percent: denominator.zero? ? 0.0 : 100.0 * covered / denominator
    )
  end

  # Every reason `rake rpc:coverage` fails. An empty array is the only pass.
  def gate_problems(report, minimum_percent:, max_unregistered:)
    problems = []
    if minimum_percent && report.percent + 1e-9 < minimum_percent.to_f
      problems << format("coverage %.2f%% is below the minimum %.1f%%", report.percent, minimum_percent.to_f)
    end
    if max_unregistered && report.unregistered_used.size > max_unregistered.to_i
      problems << "#{report.unregistered_used.size} unregistered names used, over the maximum #{max_unregistered}"
    end
    problems
  end

  # Merge one live run into the backend's evidence. Per RPC the best outcome wins (ok over
  # error); the first error text is kept for an RPC that has never answered.
  def merge_run(evidence, run_meta, outcomes)
    evidence["runs"] = (Array(evidence["runs"]) + [ run_meta ]).last(20)
    rpcs = (evidence["rpcs"] ||= {})
    outcomes.each do |name, o|
      cur = rpcs[name]
      if cur.nil? || (cur["outcome"] == "error" && o["outcome"] == "ok")
        rpcs[name] = o
      elsif cur["outcome"] == o["outcome"]
        cur["last_at"] = o["last_at"]
      end
    end
    evidence["rpcs"] = rpcs.sort.to_h
    evidence
  end
end
