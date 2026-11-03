# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"

# Practitioner.search(name, key:) asks ORWU NEWPERS for users holding a
# SECURITY KEY, as VueCentric's provider selection does with PROVIDER
# (NEWPERS^ORWU: FROM, DIR, KEY).
class PractitionerSearchKeyTest < Minitest::Test
  class Recorder
    attr_reader :calls

    def initialize = @calls = []

    def call_rpc(rpc, *params)
      @calls << [ rpc, params ]
      [ "63^PROFILE,MD" ]
    end
  end

  def setup
    @client = Recorder.new
    RpmsRpc.configure { |c| c.client = @client }
  end

  def teardown = RpmsRpc.reset!

  def test_a_key_is_sent_as_newpers_third_parameter
    RpmsRpc::Practitioner.search("PROFILE", key: "PROVIDER")
    assert_equal [ "ORWU NEWPERS", [ "PROFILE", "1", "PROVIDER" ] ], @client.calls.last
  end

  def test_without_a_key_only_the_name_and_direction_are_sent
    RpmsRpc::Practitioner.search("PROFILE")
    assert_equal [ "ORWU NEWPERS", [ "PROFILE", "1" ] ], @client.calls.last
  end
end
