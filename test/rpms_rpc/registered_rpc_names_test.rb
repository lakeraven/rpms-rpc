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

    detail = unregistered.map { |name| "  #{name}\t#{sites[name].join(' ')}" }.join("\n")
    assert_empty unregistered,
                 "#{unregistered.size} RPC name(s) used in lib/ are registered on no pinned registry " \
                 "(#{registries.map { |f| File.basename(f) }.join(', ')}):\n#{detail}"
  end
end
