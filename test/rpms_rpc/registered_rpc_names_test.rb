# frozen_string_literal: true

require "minitest/autorun"
require "set"
require_relative "../../tools/rpc_coverage/rpc_coverage"

# Every RPC name the gem uses must be registered in #8994 REMOTE PROCEDURE on at
# least one pinned registry (rpms-rpc#207, #295).
#
# A name is only real if a built baseline registers it. Mappings written from
# belief rather than a registry survived for months because nothing compared
# the declared names with a registry (the invented BMCRPC/XM/BIPC/... clusters
# of #207); this test makes that comparison on every run, offline, against the
# registries pinned under data/rpc_coverage/registry/.
#
# The names considered are the ones `rake rpc:coverage` counts as used
# (RpcCoverage.declared_names): every `m.rpc "..."` in the mappings, every
# RPC-shaped string literal on a line of lib/ that sends an RPC, and every
# capability-probe `register([...])` list.
#
# To add an RPC: pin it first, from a registry capture of a built image (the
# header of each registry file says how), then map it (ADR 0003).
class RegisteredRpcNamesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  REGISTRY_DIR = File.join(ROOT, "data/rpc_coverage/registry")

  # The IHS-cluster names the second #207 PR removes (BMCRPC, BIPC, BEHOENCX
  # tags, BYIMRT, BPHR, BHDO, MAGG, BQI MARK ALERT READ). Each entry is
  # tolerated only while the gem still uses it: an entry whose name the gem
  # no longer sends fails the test, so the list cannot outlive the mappings.
  # The list goes away with them; it is never a place to add a name.
  ALLOWED_UNTIL_THE_IHS_PURGE = [
    "BEHOENCX GET SECDEF", "BEHOENCX GET SECTION", "BEHOENCX LOCK", "BEHOENCX SAVE SECTION", "BEHOENCX UNLOCK",
    "BHDO HOSP LOC DATA", "BHDO INST DATA",
    "BIPC ELIGGET", "BIPC ELIGLIST", "BIPC IMMGET", "BIPC IMMLIST", "BIPC LOTGET", "BIPC LOTLIST",
    "BMCRPC DELREFRL", "BMCRPC GTBUDGET", "BMCRPC GTCONTRACT", "BMCRPC GTOBLIG", "BMCRPC GTOBLIGID",
    "BMCRPC GTPAYMENT", "BMCRPC GTPREFVEND", "BMCRPC GTQTRALLOC", "BMCRPC GTRATES", "BMCRPC GTREFOBLIG",
    "BMCRPC GTREMAIN", "BMCRPC GTSITPRM", "BMCRPC GTVEND", "BMCRPC SRCHVEND",
    "BPHR FACILITY DIRECT", "BPHR PATIENT DIRECT", "BPHR PROVIDER DIRECT", "BPHR RECORD ACCESS",
    "BQI MARK ALERT READ",
    "BYIMRT RSP", "BYIMRT STATUS", "BYIMRT VXQ", "BYIMRT VXU",
    "MAGG IMAGE LAUNCH TOKEN", "MAGGUSERKEYS"
  ].freeze

  def registries
    Dir[File.join(REGISTRY_DIR, "*.txt")].reject { |f| f.end_with?("-packages.txt") }.sort
  end

  def registered_names
    registries.flat_map { |f| RpcCoverage.load_registry(f).names }.to_set
  end

  def test_a_registry_is_pinned
    refute_empty registries, "no registry pinned under #{REGISTRY_DIR}"
    assert_operator registered_names.size, :>, 5_000, "a #8994 registry of a built 9.0 image has thousands of names"
  end

  def test_every_rpc_name_the_gem_uses_is_registered
    registered = registered_names
    sites = RpcCoverage.declared_names(ROOT)
    unregistered = sites.keys.reject { |name| registered.include?(name) }.sort

    stale = ALLOWED_UNTIL_THE_IHS_PURGE - unregistered
    assert_empty stale, "no longer used or now registered; remove from ALLOWED_UNTIL_THE_IHS_PURGE: #{stale.join(', ')}"

    unregistered -= ALLOWED_UNTIL_THE_IHS_PURGE
    detail = unregistered.map { |name| "  #{name}\t#{sites[name].join(' ')}" }.join("\n")
    assert_empty unregistered,
                 "#{unregistered.size} RPC name(s) used in lib/ are registered on no pinned registry " \
                 "(#{registries.map { |f| File.basename(f) }.join(', ')}):\n#{detail}"
  end
end
