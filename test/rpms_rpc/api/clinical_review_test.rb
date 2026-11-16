# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/clinical_review"

# What ClinicalReview refuses before anything is filed. Filing, reading back
# and refusing another patient's visit are proven live
# (test/live/clinical_review_live_test.rb).
class ClinicalReviewTest < Minitest::Test
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

  def test_a_patient_or_visit_that_is_not_a_positive_ien_is_refused_unsent
    [ [ nil, 118 ], [ "0", 118 ], [ 2, "" ], [ 2, "118^1" ], [ "2;3", 118 ] ].each do |dfn, visit|
      assert_equal :invalid_id, RpmsRpc::ClinicalReview.record(dfn, visit)[:error], [ dfn, visit ].inspect
    end
    assert_empty RpmsRpc::ClinicalReview.for_visit(2, "0")
    assert_empty @client.calls
  end
end
