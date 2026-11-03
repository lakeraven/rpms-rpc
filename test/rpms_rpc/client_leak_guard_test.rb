# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"

# Guard against test-order leaks: RpmsRpc.configure installs a process-wide
# client, so a test that configures one and does not reset it changes what the
# next suite sees (ConfigurationTest#test_fetch_one_raises_when_not_configured
# fails whenever it runs right after a leaking suite).
#
# Loading this file (every test file is loaded into one process by `rake test`)
# makes every test fail, after its own teardown, if it left a client configured.
# The failure names the leaking test; the client is reset first so one leak does
# not cascade into the suites that follow.
module RpmsRpc::ClientLeakGuard
  def self.leaked?
    RpmsRpc.client
    true
  rescue RpmsRpc::NotConfiguredError
    false
  end

  def after_teardown
    super
    leaked = RpmsRpc::ClientLeakGuard.leaked?
    RpmsRpc.reset!
    flunk "#{self.class}##{name} left an RpmsRpc client configured; add `RpmsRpc.reset!` to its teardown" if leaked
  end
end

Minitest::Test.prepend(RpmsRpc::ClientLeakGuard)

class RpmsRpc::ClientLeakGuardTest < Minitest::Test
  def teardown
    RpmsRpc.reset!
  end

  def test_leaked_reports_a_configured_client
    RpmsRpc.configure { |c| c.client = RpmsRpc::MockClient.new }

    assert RpmsRpc::ClientLeakGuard.leaked?
  end

  def test_leaked_is_false_once_reset
    RpmsRpc.configure { |c| c.client = RpmsRpc::MockClient.new }
    RpmsRpc.reset!

    refute RpmsRpc::ClientLeakGuard.leaked?
  end
end
