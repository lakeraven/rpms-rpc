# frozen_string_literal: true

require "json"
require "yaml"
require_relative "../../lib/rpms_rpc/conformance/build_surface"
require_relative "../../lib/rpms_rpc/test_roles"

# RPC coverage: how much of ONE backend's registered RPC surface rpms-rpc has shown working
# against that backend (rpms-rpc#270). Offline; `rake rpc:coverage` drives it.
#
#   denominator  every RPC the release under test registers (<tag>-rpcs.json, fetched by
#                `rake openrpms:fetch`, rpms-rpc#724), minus the RPCs its reach classes say no client
#                can call (computed per release, exclusions_for) and the reviewed exclusions in
#                data/rpc_coverage/exclusions.yml
#   covered      registered, not excluded, and a live run against the backend as a role other than the operator
#                (rpc-coverage/live/<backend>.<role>.json in rpms-diffs, written by `rake rpc:live`) got an answer
#                that was not a broker error (data, or an empty reply)
#
# Test roles (README, Test roles): a live run signs on as one role (ROLE=provider) and is recorded
# under it, in <backend>.<role>.json. The number counts what the roles other than the operator got
# answered. The operator holds XUPROGMODE, which skips the CIANBACT context check, so its run never
# counts toward the number: it only classifies the RPCs the other roles did not cover
# (OPERATOR_CLASSES), so a permission or context gap is told apart from an RPC broken for everyone.
# Evidence recorded before roles (runs labelled least_privilege or programmer, in <backend>.json and
# <backend>.programmer.json) still loads, and is shown as legacy: no role is claimed for it.
#
# Unit tests do not count, captured replies included: coverage here means "a real server answered"
# in a live run.
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
  # A release's rpcs.json (openrpms#713, #732) gives each registered RPC one REACH class. The uncallable classes map to an exclusion reason; the callable ones
  # (BuildSurface::CALLABLE: client-callable, broker-exempt) stay in the denominator. A class in
  # neither fails, so a new reach class is a decision here (#394).
  REACH_REASONS = {
    "no-routine" => "no_routine_on_image",
    "no-entry-point" => "no_entry_point_on_image",
    "inactive" => "inactive_on_image",
    "no-context" => "no_context",
    "out-of-order" => "context_out_of_order"
  }.freeze
  STATUSES = %w[covered live_error declared_untested not_declared].freeze
  EVIDENCE_KEYS = %w[backend runs rpcs].freeze
  # persona is read, never written: runs recorded before roles carry it instead of role.
  RUN_KEYS = %w[at rpms_rpc host_label role persona context cases tally signons].freeze
  ROLES = RpmsRpc::TestRoles
  OPERATOR = "operator"
  # The labels runs carried before roles (2026-11-22), by whether the account held XUPROGMODE.
  LEGACY_PERSONAS = %w[least_privilege programmer].freeze
  LEGACY = "legacy"
  # For an RPC no other role's run covered, what the operator's run got.
  OPERATOR_CLASSES = {
    "permission_gap" => "a role got an error (refused, timed out, dropped); the operator got an answer",
    "operator_only" => "no role sent it; the operator got an answer",
    "errors_for_both" => "an error for a role and for the operator: broken for everyone, not a permission gap",
    "errors_as_operator" => "no role sent it; the operator got an error",
    "untested_as_operator" => "no operator evidence for this RPC"
  }.freeze
  RPC_KEYS = %w[outcome error last_at].freeze

  class Error < StandardError; end

  # surface: the RpmsRpc::Conformance::BuildSurface the registry was read through.
  Registry = Struct.new(:path, :tag, :names, :header, :surface, keyword_init: true)

  module_function

  # --- inputs ---------------------------------------------------------------------------------

  # The registry: a release's <tag>-rpcs.json (fetched into tmp/openrpms/<tag>/, rpms-rpc#406, #724), read
  # through BuildSurface, the one reader of the build's surface; the tag is the document's. Any other
  # path is a flat registry, NAME first on each line ("#" lines are its header): the names file
  # openrpms bin/rpms_rpc_live_score.rb writes from a release's broker dump, scored here without a
  # release document. The tag is the file name's.
  def load_registry(path)
    raise Error, "registry not found: #{path}" unless File.exist?(path)

    if path.end_with?(".json")
      surface = RpmsRpc::Conformance::BuildSurface.from_rpcs_json(path)
      return Registry.new(path: path, tag: surface.tag, names: surface.names, header: [], surface: surface)
    end

    lines = File.readlines(path, chomp: true).reject { |l| l.strip.empty? }
    header, rows = lines.partition { |l| l.start_with?("#") }
    Registry.new(path: path, tag: File.basename(path, ".txt"),
                 names: rows.map { |l| l.split("^", 2).first }, header: header, surface: nil)
  rescue RpmsRpc::Conformance::BuildSurface::Error => e
    raise Error, e.message
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

  # --- exclusions computed from the release's reach classes (#278, #394, #406, #724) ---------------

  # name => reason for every RPC the release's rpcs.json classes as not callable.
  def unreachable_from_surface(surface)
    surface.uncallable.to_h do |name, reach|
      raise Error, "#{surface.tag}: #{name.inspect} has reach #{reach.inspect}, which rpc_coverage.rb does not map" unless REACH_REASONS.key?(reach)

      [ name, REACH_REASONS.fetch(reach) ]
    end
  end

  Regenerated = Struct.new(:exclusions, :not_in_registry, keyword_init: true)

  # The reach classes own the reach-derived reasons: they are replaced wholesale, so an RPC that became
  # callable loses its exclusion. Any other reason is a reviewed decision and is kept as it is. Only
  # names the registry registers are excluded; the rest are returned as residue to report.
  def regenerate_exclusions(current, unreachable, registry)
    generated = REACH_REASONS.values
    known = registry.names.to_h { |n| [ n, true ] }
    kept = current.reject { |_, reason| generated.include?(reason) }
    fresh = unreachable.select { |name, _| known[name] && !kept.key?(name) }
    Regenerated.new(exclusions: kept.merge(fresh).sort.to_h,
                    not_in_registry: unreachable.keys.reject { |n| known[n] }.sort)
  end

  # The reasons a person decides and data/rpc_coverage/exclusions.yml records (gui_plumbing,
  # write_needs_fixture). The reach-derived ones are computed per release, never committed.
  REVIEWED_REASONS = (EXCLUSION_REASONS.keys - REACH_REASONS.values).freeze

  # Every exclusion for a release: the REVIEWED ones (exclusions.yml) plus the reach-derived ones its
  # SURFACE computes, for the names REGISTRY registers. A Regenerated (exclusions, not_in_registry).
  def exclusions_for(reviewed, surface, registry)
    regenerate_exclusions(reviewed, unreachable_from_surface(surface), registry)
  end

  # The committed file holds reviewed decisions only: a reach-derived reason there is a release's
  # fact written down, and would go stale on the next release.
  def reviewed_problems(reviewed)
    reviewed.filter_map do |name, reason|
      next if REVIEWED_REASONS.include?(reason)

      "exclusion #{name.inspect} has reason #{reason.inspect}: exclusions.yml holds only reviewed reasons " \
        "(#{REVIEWED_REASONS.join(', ')}); the reach-derived ones are computed per release"
    end
  end

  # --- test roles -----------------------------------------------------------------------------

  # The role a run signs on as: ROLE names one of RpmsRpc::TestRoles. A run that still sets the
  # retired PERSONA is refused, naming the ROLE to set, as the live specs refuse it.
  def run_role(env = ENV)
    retired = ROLES.retired_persona_message(env)
    raise Error, retired if retired

    name = env["ROLE"].to_s.strip
    raise Error, "ROLE is not set: name the test role the run signs on as, one of #{ROLES.names.join(', ')} (README, Test roles)" if name.empty?

    ROLES.fetch(name)
  rescue ROLES::UnknownRole => e
    raise Error, e.message
  end

  # [access, verify]: RPMS_ACCESS and RPMS_VERIFY when set (a target whose codes differ), else the
  # role's published pair (the openrpms -demo image's).
  def sign_on_pair(role, env = ENV)
    access = env["RPMS_ACCESS"].to_s.strip.empty? ? role.access : env["RPMS_ACCESS"]
    verify = env["RPMS_VERIFY"].to_s.strip.empty? ? role.verify : env["RPMS_VERIFY"]
    raise Error, "ROLE=#{role.name} needs RPMS_VERIFY: #{role.account}'s verify code is not published" if verify.to_s.empty?

    [ access, verify ]
  end

  # ORWU HASKEY XUPROGMODE as reply lines: "1" when the signed-on user holds the key. A refusal or
  # an empty reply is "does not hold": a holder of XUPROGMODE is never refused, since the key skips
  # the context check.
  def holds_progmode?(lines)
    Array(lines).map(&:to_s).map(&:strip) == [ "1" ]
  end

  # nil when the signed-on account is the role's (its NEW PERSON name) and holds XUPROGMODE exactly
  # when the role's row says so; else why the run is refused. Either way a run under one role's name
  # cannot record another account's answers, and an XUPROGMODE holder cannot hide a permission gap.
  def signed_on_problem(role, user:, holds_progmode:)
    name = user.to_s.strip
    unless name == role.account
      return "ROLE=#{role.name} signed on as #{name.empty? ? 'an unnamed user' : name}, not #{role.account}: " \
             "sign on with #{role.name}'s own pair (README, Test roles)"
    end

    ROLES.xuprogmode_mismatch(role, holds: holds_progmode)
  end

  # Where a role's run is kept: <backend>.<role>.json.
  def evidence_path(dir, backend, role)
    File.join(dir, "#{backend}.#{role}.json")
  end

  # The files written before roles: the least-privilege run and the programmer run.
  def legacy_paths(dir, backend)
    { "least_privilege" => File.join(dir, "#{backend}.json"), "programmer" => File.join(dir, "#{backend}.programmer.json") }
  end

  # The label a run carries: its role, or "legacy" for a run recorded before roles.
  def run_label(run)
    return run["role"] if run["role"]

    LEGACY if run["persona"].nil? || LEGACY_PERSONAS.include?(run["persona"])
  end

  def empty_evidence(backend)
    { "backend" => backend, "runs" => [], "rpcs" => {} }
  end

  def load_evidence(path, backend)
    return empty_evidence(backend) unless path && File.exist?(path)

    JSON.parse(File.read(path))
  end

  # What rake rpc:coverage reads for BACKEND in DIR, or nil when there is nothing:
  #   as, evidence           the runs of every role but the operator, merged (union_evidence): they make the number
  #   operator_as, operator  the operator's run, or nil: it classifies what the others did not cover
  #   paths, problems        the files read, and what is wrong with any of them (evidence_problems)
  # With no role's file but the operator's, the files written before roles are read instead, as legacy.
  def coverage_inputs(dir, backend, secrets: [])
    found = ROLES.names.map(&:to_s).to_h { |r| [ r, evidence_path(dir, backend, r) ] }.select { |_, p| File.exist?(p) }
    paths = []
    problems = []
    read = lambda do |path, label|
      paths << path
      ev = load_evidence(path, backend)
      problems.concat(evidence_problems(ev, secrets: secrets, role: label).map { |p| "#{File.basename(path)}: #{p}" })
      ev
    end
    roles = found.reject { |r, _| r == OPERATOR }
    legacy = legacy_paths(dir, backend)
    operator, operator_as =
      if found[OPERATOR] then [ read.call(found[OPERATOR], OPERATOR), OPERATOR ]
      elsif roles.empty? && File.exist?(legacy["programmer"]) then [ read.call(legacy["programmer"], LEGACY), "legacy programmer, recorded before roles" ]
      end
    if roles.any?
      evidence = union_evidence(backend, roles.map { |r, p| read.call(p, r) })
      as = roles.keys.join(", ")
    elsif File.exist?(legacy["least_privilege"])
      evidence = read.call(legacy["least_privilege"], LEGACY)
      as = "legacy least_privilege, recorded before roles"
    else
      return nil
    end
    { as: as, evidence: evidence, operator: operator, operator_as: operator_as, paths: paths, problems: problems }
  end

  # Evidence is committed, so it must never carry a sign-on credential. The schema is closed
  # (no key can smuggle one in), and when the codes are in the environment the whole file is
  # searched for them.
  #
  # With role:, every run must carry that role; role: "legacy" accepts only runs recorded before roles.
  def evidence_problems(evidence, secrets: [], role: nil)
    problems = []
    extra = evidence.keys - EVIDENCE_KEYS
    problems << "live evidence has unexpected keys: #{extra.join(', ')}" unless extra.empty?
    Array(evidence["runs"]).each_with_index do |run, i|
      bad = run.keys - RUN_KEYS
      problems << "live evidence run #{i} has unexpected keys: #{bad.join(', ')}" unless bad.empty?
      problems << "live evidence run #{i} carries both role and persona" if run.key?("role") && run.key?("persona")
      next unless role

      got = run_label(run)
      problems << "live evidence run #{i} is #{got.inspect}, not #{role.inspect}" unless got == role.to_s
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
      next if f.include?("/mappings/")

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

  # as: what the covered evidence was recorded as ("provider, scheduler", or "legacy").
  Report = Struct.new(:registry, :backend, :rows, :counts, :covered, :denominator, :excluded,
                      :declared_registered, :unregistered_used, :percent, :operator, :as, keyword_init: true) do
    def one_liner
      "RPC coverage: #{format('%.1f', percent)}% (#{covered} / #{denominator} registered on #{registry.tag}; " \
        "#{excluded} excluded)#{" · as #{as}" if as} · declared #{declared_registered} · unregistered names used #{unregistered_used.size}"
    end

    def status_lines
      order = RpcCoverage::STATUSES + counts.keys.grep(/\Aexcluded:/).sort
      order.map { |s| format("  %-34s %5d", s, counts.fetch(s, 0)) }
    end

    # RPCs that answer only for the operator: a role got an error, the operator an answer.
    def permission_gaps
      rows.select { |r| r[:operator] == "permission_gap" }.map { |r| r[:name] }
    end

    def operator_counts
      rows.filter_map { |r| r[:operator] }.tally.sort.to_h
    end

    def operator_lines
      return [ "operator evidence: none (rake rpc:live ROLE=operator writes it); permission gaps not classified" ] unless operator

      gaps = permission_gaps
      [ "operator evidence (#{operator}): #{operator_counts.map { |k, v| "#{k}=#{v}" }.join(' ')}",
        "permission gaps (answer only for the operator): #{gaps.size}" ] + gaps.map { |n| "  #{n}" }
    end

    def tsv
      head = [
        "# #{one_liner}",
        "# backend: #{backend}",
        "# #{counts.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}",
        "# #{operator_lines.first}",
        "name\tstatus\tdetail\toperator"
      ]
      (head + rows.map { |r| [ r[:name], r[:status], r[:detail], r[:operator] ].join("\t") }).join("\n") + "\n"
    end

    def to_h
      { backend: backend, registry: registry.tag, percent: percent.round(2), covered: covered,
        denominator: denominator, excluded: excluded, declared_registered: declared_registered,
        unregistered_used: unregistered_used, counts: counts, as: as,
        operator: operator ? { present: true, as: operator, counts: operator_counts, permission_gaps: permission_gaps } : { present: false } }
    end
  end

  # evidence: what the roles other than the operator got (union_evidence), recorded as AS.
  # operator: the operator's evidence, or nil, recorded as OPERATOR_AS. It never changes a status or the number.
  def compute(registry:, declared:, evidence:, exclusions:, backend:, operator: nil, as: nil, operator_as: OPERATOR)
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
    rows.each { |r| r[:operator] = operator_class(r[:status], operator["rpcs"]&.dig(r[:name])) } if operator
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
      operator: operator && operator_as, as: as
    )
  end

  # Covered and excluded RPCs have no class: there is nothing for the operator's run to explain.
  def operator_class(status, op)
    return nil if status == "covered" || status.start_with?("excluded:")
    return "untested_as_operator" unless op

    sent = status == "live_error"
    if op["outcome"] == "ok"
      sent ? "permission_gap" : "operator_only"
    else
      sent ? "errors_for_both" : "errors_as_operator"
    end
  end

  # One evidence document from several roles' runs: per RPC the best outcome wins, as merge_run keeps it.
  def union_evidence(backend, evidences)
    out = empty_evidence(backend)
    evidences.each do |ev|
      out["runs"] += Array(ev["runs"])
      rpcs = out["rpcs"]
      (ev["rpcs"] || {}).each do |name, o|
        rpcs[name] = o.dup if rpcs[name].nil? || (rpcs[name]["outcome"] == "error" && o["outcome"] == "ok")
      end
    end
    out["rpcs"] = out["rpcs"].sort.to_h
    out
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
