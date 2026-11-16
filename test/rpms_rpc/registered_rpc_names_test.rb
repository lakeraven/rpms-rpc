# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/conformance/release_inventory"
require_relative "release_under_test"
require_relative "../../tools/rpc_coverage/rpc_coverage"

# Every RPC name the gem uses must be available on the openrpms release under test
# (rpms-rpc#207, #295, #222, #724).
#
# A name is only real if a built baseline registers it. Mappings written from
# belief rather than a registry survived for months because nothing compared
# the declared names with a registry (the invented BMCRPC/XM/BIPC/... clusters
# of #207). This test makes that comparison on every run against the RPC
# signature openrpms published for the release under test: the latest published
# -ydb release, or OPENRPMS_RELEASE=<tag> (`rake openrpms:fetch`;
# test/rpms_rpc/release_under_test.rb). data/rpc_coverage/config.yml's
# max_unregistered: 0 is this gate.
#
# "Available" here is what the build signature can show from the #8994 0-node
# (^DD(8994): .01 NAME, .02 TAG, .03 ROUTINE, .06 INACTIVE):
#   - registered: the name has a #8994 entry on the build;
#   - has an entry point: TAG and ROUTINE are both set;
#   - not inactive for local use: INACTIVE is not 1 (inactive) or 2 (local inactive).
# Whether that entry point exists on the image and a context allows it (callable)
# is the stricter gate in callable_rpc_names_test.rb (#394), from the build's reach face.
# Both read the release's files through RpmsRpc::Conformance::BuildSurface.
#
# The names considered are the ones `rake rpc:coverage` counts as used
# (RpcCoverage.declared_names): every `m.rpc "..."` in the mappings, every
# RPC-shaped string literal on a line of lib/ that sends an RPC.
#
# To add an RPC: it must be on a published openrpms release first, then map it (ADR 0003).
class RegisteredRpcNamesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  Release = RpmsRpc::Conformance::ReleaseInventory

  def test_the_release_under_test_has_a_full_registry
    inv = ReleaseUnderTest.inventory(self)
    assert_operator inv.surface.names.size, :>, 5_000, "#{inv.tag}: a #8994 registry of a built 9.0 image has thousands of names"
  end

  def test_every_rpc_name_the_gem_uses_is_available_on_the_release_under_test
    inv = ReleaseUnderTest.inventory(self)
    sites = RpcCoverage.declared_names(ROOT)
    problems = sites.keys.sort.filter_map do |name|
      why = Release.unavailable_reason(inv.surface[name])
      "  #{name}\t#{why} on #{inv.tag}\t#{sites[name].join(' ')}" if why
    end

    assert_empty problems,
                 "#{problems.size} RPC name(s) used in lib/ are not available on #{inv.tag}:\n" \
                 "#{problems.join("\n")}"
  end

  # The reasons the gate gives, on the shapes a real #8994 dump has
  # (openrpms bcer-9.0-20260930-8c88e47-ydb: BPC GETLABVISITDATA has no entry
  # point, XUS CCOW VAULT PARAM is INACTIVE=3, remote only).
  def test_unavailable_reasons
    reason = ->(meta) { Release.unavailable_reason(meta) }

    assert_equal "not registered", reason.(nil)
    assert_equal "registered without an entry point", reason.({ "tag" => nil, "routine" => nil })
    assert_equal "registered without an entry point", reason.({ "tag" => "X", "routine" => "" })
    assert_equal "INACTIVE=1 in #8994", reason.({ "tag" => "A", "routine" => "B", "inactive" => "1" })
    assert_equal "INACTIVE=2 in #8994", reason.({ "tag" => "A", "routine" => "B", "inactive" => "2" })
    assert_nil reason.({ "tag" => "CCOWPC", "routine" => "XUSRB4", "inactive" => "3" })
    assert_nil reason.({ "tag" => "A", "routine" => "B", "inactive" => "0" })
    assert_nil reason.({ "tag" => "A", "routine" => "B" })
  end

  # The same reasons from the reader's records (the committed fixture, cut from a real release).
  def test_unavailable_reasons_from_the_build_surface
    surface = ReleaseUnderTest.fixture.surface
    reason = ->(name) { Release.unavailable_reason(surface[name]) }

    assert_equal "registered without an entry point", reason.("BPC GETLABVISITDATA")
    assert_nil reason.("XUS CCOW VAULT PARAM")
    assert_nil reason.("ORWPT SELECT")
    assert_equal "not registered", reason.("ZZZ NOT REGISTERED")
  end
end
