# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/conformance/inventory_lock"
require_relative "../../tools/rpc_coverage/rpc_coverage"

# Every RPC name the gem uses must be available on every pinned rpms-ops build
# (rpms-rpc#207, #295, #222).
#
# A name is only real if a built baseline registers it. Mappings written from
# belief rather than a registry survived for months because nothing compared
# the declared names with a registry (the invented BMCRPC/XM/BIPC/... clusters
# of #207). This test makes that comparison on every run, offline, against the
# RPC signature rpms-ops published for a named build: the release inventory
# pinned in data/fingerprints/rpms-ops.lock.yml (`rake conformance:pin`).
#
# "Available" here is what the build signature can show from the #8994 0-node
# (^DD(8994): .01 NAME, .02 TAG, .03 ROUTINE, .06 INACTIVE):
#   - registered: the name has a #8994 entry on the build;
#   - has an entry point: TAG and ROUTINE are both set;
#   - not inactive for local use: INACTIVE is not 1 (inactive) or 2 (local inactive).
# Whether that entry point exists on the image and a context allows it (callable)
# is the stricter gate in callable_rpc_names_test.rb (#394), from the build's reach face.
# Both read the pinned files through RpmsRpc::Conformance::BuildSurface.
#
# The names considered are the ones `rake rpc:coverage` counts as used
# (RpcCoverage.declared_names): every `m.rpc "..."` in the mappings, every
# RPC-shaped string literal on a line of lib/ that sends an RPC.
#
# To add an RPC: pin a build that serves it first (`rake conformance:pin`), then
# map it (ADR 0003).
class RegisteredRpcNamesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  FINGERPRINTS_DIR = File.join(ROOT, "data/fingerprints")
  LOCK = RpmsRpc::Conformance::InventoryLock.load(File.join(FINGERPRINTS_DIR, "rpms-ops.lock.yml"))

  def pinned_builds
    @pinned_builds ||= LOCK.surfaces(inventories_dir: File.join(ROOT, "data/inventories"))
  end

  def test_a_build_is_pinned
    refute_empty pinned_builds, "no rpms-ops build pinned in #{LOCK.path}"
    pinned_builds.each do |tag, surface|
      assert_operator surface.names.size, :>, 5_000, "#{tag}: a #8994 registry of a built 9.0 image has thousands of names"
    end
  end

  def test_every_rpc_name_the_gem_uses_is_available_on_every_pinned_build
    sites = RpcCoverage.declared_names(ROOT)
    problems = pinned_builds.flat_map do |tag, surface|
      sites.keys.sort.filter_map do |name|
        why = RpmsRpc::Conformance::InventoryLock.unavailable_reason(surface[name])
        "  #{name}\t#{why} on #{tag}\t#{sites[name].join(' ')}" if why
      end
    end

    assert_empty problems,
                 "#{problems.size} RPC name(s) used in lib/ are not available on a pinned rpms-ops build:\n" \
                 "#{problems.join("\n")}"
  end

  # The reasons the gate gives, on the shapes a real #8994 dump has
  # (rpms-ops bcer-9.0-20260930-8c88e47-ydb: BPC GETLABVISITDATA has no entry
  # point, XUS CCOW VAULT PARAM is INACTIVE=3, remote only).
  def test_unavailable_reasons
    reason = ->(meta) { RpmsRpc::Conformance::InventoryLock.unavailable_reason(meta) }

    assert_equal "not registered", reason.(nil)
    assert_equal "registered without an entry point", reason.({ "tag" => nil, "routine" => nil })
    assert_equal "registered without an entry point", reason.({ "tag" => "X", "routine" => "" })
    assert_equal "INACTIVE=1 in #8994", reason.({ "tag" => "A", "routine" => "B", "inactive" => "1" })
    assert_equal "INACTIVE=2 in #8994", reason.({ "tag" => "A", "routine" => "B", "inactive" => "2" })
    assert_nil reason.({ "tag" => "CCOWPC", "routine" => "XUSRB4", "inactive" => "3" })
    assert_nil reason.({ "tag" => "A", "routine" => "B", "inactive" => "0" })
    assert_nil reason.({ "tag" => "A", "routine" => "B" })
  end

  # The same reasons from the reader's records.
  def test_unavailable_reasons_from_the_build_surface
    surface = pinned_builds.values.first
    reason = ->(name) { RpmsRpc::Conformance::InventoryLock.unavailable_reason(surface[name]) }

    assert_equal "registered without an entry point", reason.("BPC GETLABVISITDATA")
    assert_nil reason.("XUS CCOW VAULT PARAM")
    assert_nil reason.("ORWPT SELECT")
    assert_equal "not registered", reason.("ZZZ NOT REGISTERED")
  end
end
