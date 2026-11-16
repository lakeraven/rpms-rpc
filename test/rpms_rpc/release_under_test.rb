# frozen_string_literal: true

require "rpms_rpc"
require "rpms_rpc/conformance/release_inventory"

# The two kinds of release data the tests read (rpms-rpc#724):
#
#   ReleaseUnderTest.inventory   the openrpms release the gem is tested against: the latest published
#                                -ydb release (or OPENRPMS_RELEASE=<tag>), fetched into tmp/openrpms/.
#                                The gates read it: every name the gem sends registered, every RPC
#                                callable, every feature's RPCs served.
#   ReleaseUnderTest::FIXTURE_*  a small inventory cut from a real release (tools/fixture_inventory.rb),
#                                committed, for unit tests of the readers that must stay offline.
#
# The gates need the network the first time (`rake openrpms:fetch` records the release; afterwards they
# read it offline). With OPENRPMS_OFFLINE=1 a gate test SKIPS, saying so: the hermetic CI job sets it,
# and the release-gate job runs the same tests with the release fetched. Without it, a release that
# cannot be fetched FAILS the test with the reason, never a silent pass.
module ReleaseUnderTest
  Release = RpmsRpc::Conformance::ReleaseInventory
  ROOT = File.expand_path("../..", __dir__)
  OFFLINE_ENV = "OPENRPMS_OFFLINE"
  # Read once, when the tests load: a test that points Features at the fixture (OPENRPMS_INVENTORIES)
  # must not move the release the gates judge.
  CACHE = Release.cache_root
  FIXTURE_ROOT = File.join(ROOT, "test/fixtures/inventories")
  FIXTURE_TAG = "bcer-9.0-20261012-e7923a4-ydb"
  FIXTURE_DIR = File.join(FIXTURE_ROOT, FIXTURE_TAG)

  module_function

  # The verified Inventory of the release under test, or skip/flunk in TEST (a Minitest::Test).
  def inventory(test)
    result = resolved
    return result unless result.is_a?(String)

    test.skip("release gate not run: #{result}") if offline?
    test.flunk("no openrpms release to test against: #{result}")
  end

  def surface(test) = inventory(test).surface

  def offline? = ENV[OFFLINE_ENV] == "1"

  # Inventory, or the reason there is none. Memoized for the process.
  def resolved
    return @resolved if defined?(@resolved)

    @resolved =
      begin
        current = Release.current(root: CACHE)
        override = ENV[Release::TAG_ENV].to_s.strip
        override.empty? || current.tag == override ? current : refetch("current.json names #{current.tag}, not #{override}")
      rescue Release::Error => e
        refetch(e.message)
      end
  end

  def refetch(why) = offline? ? "#{OFFLINE_ENV}=1 (#{why})" : fetch_or_reason

  def fetch_or_reason
    Release.resolve!(root: CACHE)
  rescue Release::Error => e
    e.message
  end

  # The committed fixture inventory, verified.
  def fixture = @fixture ||= Release.verify_dir(FIXTURE_TAG, FIXTURE_DIR)
end
