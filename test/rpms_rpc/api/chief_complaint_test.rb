# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/chief_complaint"

# What ChiefComplaint refuses before anything reaches the wire. Filing and
# reading back are proven live (test/live/chief_complaint_live_test.rb).
class ChiefComplaintTest < Minitest::Test
  class RecordingClient
    attr_reader :calls

    def initialize = @calls = []

    def call_rpc(name, *params)
      @calls << [ name, params ]
      ""
    end
  end

  def setup
    @client = RecordingClient.new
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_text_the_piece_cannot_carry_is_refused_unsent
    [ "", "   ", "pain^nausea", "pain\nnausea", "x" * 241, nil, 42 ].each do |text|
      assert_equal :invalid_text, RpmsRpc::ChiefComplaint.record(118, text)[:error], text.inspect
    end
    assert_empty @client.calls
  end

  def test_a_visit_that_is_not_a_positive_ien_is_refused_unsent
    [ nil, "", "0", "-3", "12a", "118^1" ].each do |visit|
      assert_equal :invalid_visit, RpmsRpc::ChiefComplaint.record(visit, "Cough")[:error], visit.inspect
    end
    assert_empty RpmsRpc::ChiefComplaint.for_visit("0")
    assert_empty @client.calls
  end
end
