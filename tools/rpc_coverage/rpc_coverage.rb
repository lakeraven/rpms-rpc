# frozen_string_literal: true

require "json"
require "yaml"

# RPC coverage: how much of ONE backend's registered RPC surface rpms-rpc has shown working
# against that backend (rpms-rpc#270). Offline; `rake rpc:coverage` drives it.
#
#   denominator  every #8994 NAME on the pinned build (data/inventories/<tag>/<tag>-broker_8994.txt),
#                minus the names data/rpc_coverage/exclusions.yml excludes with a reason
#   covered      registered, not excluded, and a live run against the backend
#                (rpc-coverage/live/<backend>.json in rpms-diffs, written by `rake rpc:live`) got an answer
#                that was not a broker error (data, or an empty reply)
#
# Personas (#335): the headline is measured as the least-privilege user (no XUPROGMODE), the user a
# web client signs on as. A programmer run (XUPROGMODE skips the CIANBACT context check) is kept
# beside it in <backend>.programmer.json and never counts toward the number: it only classifies the
# RPCs the least-privilege run did not cover (PROGRAMMER_CLASSES), so a permission or context gap is
# told apart from an RPC that is broken for everyone.
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
    "no_entry_point_on_image" => "registered, the routine is on the image, but the TAG it names is not",
    "inactive_on_image" => "registered, but #8994 INACTIVE is set on the image",
    "no_context" => "no option's RPC multiple lists it, so no client can bind a context that allows it",
    "context_out_of_order" => "every context that lists it is OUT OF ORDER as shipped; a site can put one back in service",
    "gui_plumbing" => "drives a thick-client GUI (layout, window state); no headless use (ADR-0004 tiers)",
    "write_needs_fixture" => "a write or side effect that needs a disposable fixture before it can run live"
  }.freeze
  # The RPC atlas (cloud-rpms scripts/shared/rpc-atlas.sh) gives each registered RPC one REACH class.
  # The unreachable classes map to an exclusion reason; broker-exempt and client-callable RPCs stay
  # in the denominator. A class missing from both lists fails, so a new atlas class is a decision here.
  ATLAS_REACH_REASONS = {
    "no-routine" => "no_routine_on_image",
    "no-entry-point" => "no_entry_point_on_image",
    "inactive" => "inactive_on_image",
    "no-context" => "no_context",
    "out-of-order" => "context_out_of_order"
  }.freeze
  ATLAS_REACHABLE = %w[broker-exempt client-callable].freeze
  STATUSES = %w[covered live_error declared_untested not_declared].freeze
  EVIDENCE_KEYS = %w[backend runs rpcs].freeze
  RUN_KEYS = %w[at rpms_rpc host_label persona context cases tally signons].freeze
  PERSONAS = %w[least_privilege programmer].freeze
  DEFAULT_PERSONA = "least_privilege"
  # For an RPC the least-privilege run did not cover, what the programmer run got.
  PROGRAMMER_CLASSES = {
    "permission_gap" => "least-privilege got an error (refused, timed out, dropped); a programmer got an answer",
    "programmer_only" => "least-privilege never sent it; a programmer got an answer",
    "errors_for_both" => "an error for both users: broken for everyone, not a permission gap",
    "errors_as_programmer" => "least-privilege never sent it; a programmer got an error",
    "untested_as_programmer" => "no programmer evidence for this RPC"
  }.freeze
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

      # An rpms-ops broker dump has one #8994 0-node per line, NAME first (#222).
      l.start_with?("#") ? header << l : names << l.split("^", 2).first
    end
    Registry.new(path: path, tag: File.basename(path, ".txt").delete_suffix("-broker_8994"), names: names, header: header)
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

  # With live evidence, an excluded RPC that answered is a stale exclusion: the reason no longer holds.
  def exclusion_problems(exclusions, registry, evidence: nil)
    known = registry.names.to_h { |n| [ n, true ] }
    live = (evidence && evidence["rpcs"]) || {}
    exclusions.flat_map do |name, reason|
      out = []
      out << "exclusion #{name.inspect} is not registered on #{registry.tag}" unless known[name]
      out << "exclusion #{name.inspect} has unknown reason #{reason.inspect} (allowed: #{EXCLUSION_REASONS.keys.join(', ')})" unless EXCLUSION_REASONS.key?(reason)
      out << "exclusion #{name.inspect} (#{reason}) answered live: the exclusion is stale, remove it" if live.dig(name, "outcome") == "ok"
      out
    end
  end

  # --- exclusions generated from the RPC atlas (#278) -----------------------------------------

  # name => reason for every RPC the atlas classes as unreachable.
  def unreachable_from_atlas(path)
    raise Error, "atlas not found: #{path}" unless File.exist?(path)

    lines = File.readlines(path, chomp: true).reject { |l| l.strip.empty? || l.start_with?("#") }
    head = lines.shift.to_s.split("\t")
    ni = head.index("name")
    ri = head.index("reach")
    raise Error, "#{path} has no name and reach columns (not an rpc-atlas atlas.tsv?)" unless ni && ri

    lines.each_with_object({}) do |l, out|
      cols = l.split("\t", -1)
      name = cols[ni]
      reach = cols[ri]
      next if ATLAS_REACHABLE.include?(reach)
      raise Error, "#{path}: #{name.inspect} has reach #{reach.inspect}, which rpc_coverage.rb does not map" unless ATLAS_REACH_REASONS.key?(reach)

      out[name] = ATLAS_REACH_REASONS.fetch(reach)
    end
  end

  Regenerated = Struct.new(:exclusions, :not_in_registry, keyword_init: true)

  # The atlas owns the atlas-derived reasons: they are replaced wholesale, so an RPC that became
  # callable loses its exclusion. Any other reason is a reviewed decision and is kept as it is. Only
  # names the pinned registry registers are excluded; the rest are returned as residue to report.
  def regenerate_exclusions(current, unreachable, registry)
    generated = ATLAS_REACH_REASONS.values
    known = registry.names.to_h { |n| [ n, true ] }
    kept = current.reject { |_, reason| generated.include?(reason) }
    fresh = unreachable.select { |name, _| known[name] && !kept.key?(name) }
    Regenerated.new(exclusions: kept.merge(fresh).sort.to_h,
                    not_in_registry: unreachable.keys.reject { |n| known[n] }.sort)
  end

  def exclusions_yaml(exclusions, source:)
    width = EXCLUSION_REASONS.keys.map(&:size).max
    head = [
      "# RPCs left out of the rpc:coverage denominator, each with a reason from this fixed vocabulary",
      "# (any other reason, or a name the registry does not register, fails the task; so does an",
      "# excluded RPC that answered live):",
      "#"
    ]
    head += EXCLUSION_REASONS.map { |r, why| "#   #{r.ljust(width)}  #{why}" }
    head += [
      "#",
      "# The unreachable reasons (no_routine_on_image .. context_out_of_order) are GENERATED from the",
      "# cloud-rpms RPC atlas of the pinned release by `rake rpc:exclusions`; regenerate each release,",
      "# never hand-edit them. gui_plumbing and write_needs_fixture are reviewed decisions: add one per",
      "# PR with its evidence; regeneration keeps them.",
      "#"
    ]
    head += source.map { |l| "# #{l}" }
    head += exclusions.values.tally.sort.map { |r, n| "# count #{r}: #{n}" }
    body = exclusions.sort.map { |name, reason| "#{name.to_json}: #{reason}" }
    body = [ "{}" ] if body.empty?
    (head + body).join("\n") + "\n"
  end

  # --- personas (#335) ------------------------------------------------------------------------

  def persona(value)
    v = value.to_s.empty? ? DEFAULT_PERSONA : value.to_s
    raise Error, "PERSONA=#{v} is not one of #{PERSONAS.join(', ')}" unless PERSONAS.include?(v)

    v
  end

  # The least-privilege file keeps the path it has always had; a programmer run is written beside it.
  def evidence_path(dir, backend, persona)
    File.join(dir, persona == DEFAULT_PERSONA ? "#{backend}.json" : "#{backend}.#{persona}.json")
  end

  # ORWU HASKEY XUPROGMODE as reply lines: "1" when the signed-on user holds the key. A refusal or
  # an empty reply is "does not hold": a programmer is never refused, since XUPROGMODE skips the
  # context check.
  def holds_progmode?(lines)
    Array(lines).map(&:to_s).map(&:strip) == [ "1" ]
  end

  # The persona label is a claim about the signed-on user, checked before any evidence is written.
  def persona_problem(persona, holds_progmode:)
    if persona == "programmer" && !holds_progmode
      "PERSONA=programmer but the signed-on user does not hold XUPROGMODE"
    elsif persona != "programmer" && holds_progmode
      "PERSONA=#{persona} but the signed-on user holds XUPROGMODE (a programmer skips the context check)"
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
  #
  # With persona:, every run must be that persona's. A least-privilege run recorded before runs
  # carried the label (#335) has none and is accepted; a programmer file must say so on every run.
  def evidence_problems(evidence, secrets: [], persona: nil)
    problems = []
    extra = evidence.keys - EVIDENCE_KEYS
    problems << "live evidence has unexpected keys: #{extra.join(', ')}" unless extra.empty?
    Array(evidence["runs"]).each_with_index do |run, i|
      bad = run.keys - RUN_KEYS
      problems << "live evidence run #{i} has unexpected keys: #{bad.join(', ')}" unless bad.empty?
      next unless persona

      got = run["persona"]
      next if got == persona || (got.nil? && persona == DEFAULT_PERSONA)

      problems << "live evidence run #{i} is persona #{got.inspect}, not #{persona.inspect}"
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
  # frame (`pk("RPC")`, cia_client.rb).
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

      File.readlines(f).each_with_index do |l, i|
        code = l.sub(/\s#.*$/, "")
        next if code.strip.start_with?("#")

        sends = code.gsub(/"[^"]*"/, '""').match?(RPC_LINE) || code.match?(CIA_FRAME)
        code.scan(RPC_STRING) { |(n)| sites[n] << "#{rel(f, root)}:#{i + 1}" } if sends
      end
    end
    sites
  end

  def rel(path, root) = path.delete_prefix("#{File.expand_path(root)}/").delete_prefix("#{root}/")

  # --- the report -----------------------------------------------------------------------------

  Report = Struct.new(:registry, :backend, :rows, :counts, :covered, :denominator, :excluded,
                      :declared_registered, :unregistered_used, :percent, :programmer, keyword_init: true) do
    def one_liner
      "RPC coverage: #{format('%.1f', percent)}% (#{covered} / #{denominator} registered on #{registry.tag}; " \
        "#{excluded} excluded) · declared #{declared_registered} · unregistered names used #{unregistered_used.size}"
    end

    def status_lines
      order = RpcCoverage::STATUSES + counts.keys.grep(/\Aexcluded:/).sort
      order.map { |s| format("  %-34s %5d", s, counts.fetch(s, 0)) }
    end

    # RPCs that answer only for a programmer: least-privilege got an error, a programmer an answer.
    def permission_gaps
      rows.select { |r| r[:programmer] == "permission_gap" }.map { |r| r[:name] }
    end

    def programmer_counts
      rows.filter_map { |r| r[:programmer] }.tally.sort.to_h
    end

    def programmer_lines
      return [ "programmer evidence: none (rake rpc:live PERSONA=programmer writes it); permission gaps not classified" ] unless programmer

      gaps = permission_gaps
      [ "programmer evidence: #{programmer_counts.map { |k, v| "#{k}=#{v}" }.join(' ')}",
        "permission gaps (answer only for a programmer): #{gaps.size}" ] + gaps.map { |n| "  #{n}" }
    end

    def tsv
      head = [
        "# #{one_liner}",
        "# backend: #{backend}",
        "# #{counts.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}",
        "# #{programmer_lines.first}",
        "name\tstatus\tdetail\tprogrammer"
      ]
      (head + rows.map { |r| [ r[:name], r[:status], r[:detail], r[:programmer] ].join("\t") }).join("\n") + "\n"
    end

    def to_h
      { backend: backend, registry: registry.tag, percent: percent.round(2), covered: covered,
        denominator: denominator, excluded: excluded, declared_registered: declared_registered,
        unregistered_used: unregistered_used, counts: counts,
        programmer: programmer ? { present: true, counts: programmer_counts, permission_gaps: permission_gaps } : { present: false } }
    end
  end

  # programmer: the programmer persona's evidence, or nil. It never changes a status or the number.
  def compute(registry:, declared:, evidence:, exclusions:, backend:, programmer: nil)
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
    rows.each { |r| r[:programmer] = programmer_class(r[:status], programmer["rpcs"]&.dig(r[:name])) } if programmer
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
      percent: denominator.zero? ? 0.0 : 100.0 * covered / denominator,
      programmer: !programmer.nil?
    )
  end

  # Covered and excluded RPCs have no class: there is nothing for a programmer run to explain.
  def programmer_class(status, prog)
    return nil if status == "covered" || status.start_with?("excluded:")
    return "untested_as_programmer" unless prog

    sent = status == "live_error"
    if prog["outcome"] == "ok"
      sent ? "permission_gap" : "programmer_only"
    else
      sent ? "errors_for_both" : "errors_as_programmer"
    end
  end

  # Every reason `rake rpc:coverage` fails. An empty array is the only pass. The coverage number is
  # not one of them: see coverage_notes.
  def gate_problems(report, max_unregistered:)
    problems = []
    if max_unregistered && report.unregistered_used.size > max_unregistered.to_i
      problems << "#{report.unregistered_used.size} unregistered names used, over the maximum #{max_unregistered}"
    end
    problems
  end

  # The coverage number never fails the task, so a live run that loses an answer does not block
  # unrelated work. It is compared with minimum_percent, the last recorded value, and the result is
  # printed as a note: a drop is reported, and a rise says what to record so the next drop is visible.
  def coverage_notes(report, minimum_percent:)
    return [] unless minimum_percent

    floor = minimum_percent.to_f
    shown = format("%.1f", report.percent).to_f
    if report.percent + 1e-9 < floor
      [ format("coverage %.2f%% is below the recorded %.1f%%: an RPC that answered before no longer does", report.percent, floor) ]
    elsif shown > floor
      [ format("coverage rose to %.1f%%: set minimum_percent: %.1f in data/rpc_coverage/config.yml", shown, shown) ]
    else
      []
    end
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
