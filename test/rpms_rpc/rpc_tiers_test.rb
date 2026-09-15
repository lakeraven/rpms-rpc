# frozen_string_literal: true

require "minitest/autorun"
require "set"
require "yaml"

# Enforces ADR 0004: the canonical stack stays frontend-agnostic.
#
# The legacy set is not a backlog. An RPC lands there because we decided its
# contract presumes a legacy client, so wrapping it is a design error rather
# than a coverage gain. This test is what makes that decision stick.
class RpmsRpc::RpcTiersTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  TIER_DIR = File.join(ROOT, "data", "rpc_tiers")

  # Wrappers we knowingly keep despite a legacy classification, permanently.
  # Each entry needs a reason; an empty reason fails the test.
  JUSTIFIED_LEGACY_WRAPPERS = {
    # "ORWCH SAVESIZ" => "reason it must exist despite being view-tier"
  }.freeze

  # Legacy-coupled wrappers that predate ADR 0004. This is a ratchet, not an
  # exemption: the set may SHRINK but never grow, so no new coupling can enter
  # while these are burned down. Each carries its replacement path.
  GRANDFATHERED = {
    "CIAVMRPC GETPAR" =>
      "Fetches the VueCentric client's config root ('CIAVM DEFAULT SOURCE'). " \
      "A frontend-agnostic consumer has no CIAVM config root. Delete with the " \
      "session-bootstrap path; no replacement needed.",
    "BGOTRG GETSUM" =>
      "Scrapes the rendered triage-summary string for reminders because the real " \
      "reminder RPCs were never modelled (see the mapping's own comment). Replace " \
      "with ORQQPXRM REMINDERS UNEVALUATED + ORQQPXRM REMINDER CATEGORIES, both " \
      "canonical and both observed in the trace.",
    "TIU TEMPLATE GETBOIL" => "Note-template expansion; arguable tier, see ADR 0004 consequences.",
    "TIU TEMPLATE GETITEMS" => "Template tree traversal for an editor picker; arguable tier.",
    "TIU TEMPLATE GETTEXT" => "Template text for an editor widget; arguable tier."
  }.freeze

  def tier_set(name)
    File.readlines(File.join(TIER_DIR, "#{name}.txt"), chomp: true)
        .reject { |l| l.strip.empty? || l.start_with?("#") }
        .map { |l| l.split("\t").first.strip }
        .to_set
  end

  # Same source-scan the coverage matrix uses (bin/build_coverage_matrix:34),
  # so the gate and the reported numbers can never disagree.
  def wrapped_rpcs
    Dir.glob(File.join(ROOT, "lib/{rpms_rpc,vista_rpc}/mappings{.rb,/*.rb}"))
       .flat_map { |f| File.read(f).scan(/\.rpc\s+["']([^"']+)["']/).flatten }
       .map(&:strip).to_set
  end

  def test_tier_files_are_disjoint
    canonical = tier_set("canonical")
    quarantine = tier_set("quarantine")
    legacy = tier_set("legacy")

    assert_empty (canonical & legacy).to_a, "RPC is both canonical and legacy"
    assert_empty (canonical & quarantine).to_a, "RPC is both canonical and quarantine"
    assert_empty (quarantine & legacy).to_a, "RPC is both quarantine and legacy"
    refute_empty legacy, "legacy set is empty — tier data missing or unreadable"
  end

  def test_rules_tiers_do_not_overlap
    rules = YAML.safe_load_file(File.join(TIER_DIR, "rules.yml"))
    %w[view dialog control].combination(2) do |a, b|
      dup = (Set.new(rules.fetch(a)) & Set.new(rules.fetch(b))).to_a
      assert_empty dup, "rules.yml: #{a} and #{b} both claim #{dup.join(', ')}"
    end
  end

  def test_no_new_mapping_wraps_a_legacy_coupled_rpc
    known = JUSTIFIED_LEGACY_WRAPPERS.keys.to_set | GRANDFATHERED.keys.to_set
    offenders = (wrapped_rpcs & tier_set("legacy")) - known

    assert_empty offenders.to_a, <<~MSG
      These RPCs are classified legacy (ADR 0004) but have new mappings:

        #{offenders.to_a.sort.join("\n  ")}

      A legacy RPC's contract presumes the VueCentric shell, the CPRS
      order-dialog machine, or the TIU note editor. Wrapping one pulls that
      client's shape into our stack.

      Resolve by one of:
        - remove the mapping (usually right), or
        - re-tier the RPC in data/rpc_tiers/rules.yml if the classification is
          wrong, and say why in the ADR, or
        - add it to JUSTIFIED_LEGACY_WRAPPERS here WITH a reason.

      Do NOT add it to GRANDFATHERED — that set is closed and may only shrink.
    MSG
  end

  # The ratchet. If a grandfathered wrapper has been removed, this fails and
  # tells you to delete the entry, so the debt list cannot drift out of date.
  def test_grandfathered_set_only_shrinks
    stale = GRANDFATHERED.keys.to_set - wrapped_rpcs

    assert_empty stale.to_a, <<~MSG
      GRANDFATHERED lists RPCs that no longer have mappings:

        #{stale.to_a.sort.join("\n  ")}

      The debt was paid — remove these entries so the list stays honest.
    MSG
  end

  def test_every_exception_carries_a_reason
    JUSTIFIED_LEGACY_WRAPPERS.merge(GRANDFATHERED).each do |rpc, reason|
      refute_empty reason.to_s.strip, "#{rpc} is exempted with no reason given"
    end
  end
end
