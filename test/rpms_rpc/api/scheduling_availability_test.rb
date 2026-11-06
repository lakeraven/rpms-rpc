# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"

# Scheduling.add_availability refuses, before anything is sent, the values AVADD^BSDX12
# would quietly accept: it swaps a start after the end, and files a block of no slots.
# What RPMS does with a block it accepts is proven live (test/live/scheduling_availability_live_test.rb).
class SchedulingAvailabilityTest < Minitest::Test
  class RecordingClient
    attr_reader :calls

    def initialize = @calls = []

    def with_context(_name) = yield

    def call_rpc(rpc, *params)
      @calls << [ rpc, params ]
      raise "no RPC should be sent"
    end
  end

  def setup
    @client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = @client }
  end

  def teardown = RpmsRpc.reset!

  def add(start_time:, end_time:, slots: 1)
    RpmsRpc::Scheduling.add_availability(resource: "DEMO IHS CLINIC", start_time: start_time, end_time: end_time,
                                         slots: slots, access_type_id: 1)
  end

  def test_an_end_not_after_the_start_is_refused_before_anything_is_sent
    eight = Time.new(2027, 1, 4, 8, 0, 0)

    assert_raises(ArgumentError) { add(start_time: eight, end_time: eight) }
    assert_raises(ArgumentError) { add(start_time: eight + 3600, end_time: eight) }
    assert_empty @client.calls
  end

  def test_a_block_of_no_slots_is_refused_before_anything_is_sent
    eight = Time.new(2027, 1, 4, 8, 0, 0)

    assert_raises(ArgumentError) { add(start_time: eight, end_time: eight + 3600, slots: 0) }
    assert_empty @client.calls
  end
end
