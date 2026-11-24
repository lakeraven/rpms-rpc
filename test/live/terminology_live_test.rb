# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/terminology"

# RpmsRpc::Terminology on a real build (rpms-rpc#916): SNOMED CT search,
# concept detail and code sets from the local BSTS cache, under BSTSRPC.
# The provider's row holds BSTSRPC; the front desk clerk's does not, and the
# broker refuses it the option, which raises rather than reading as no
# concepts. Reads only.
class TerminologyLiveTest < LiveSpec::Test
  runs_as :provider, :front_desk_clerk

  def test_search_then_detail_then_code_sets
    return refused_without_bstsrpc if role == :front_desk_clerk

    concepts = RpmsRpc::Terminology.search("diabetes")
    refute_empty concepts
    concepts.each do |c|
      assert_match(/\A\d+\z/, c[:concept_id], c.inspect)
      refute_empty c[:term], c.inspect
      c[:icd].each { |code| assert_match(/\A[A-Z]\d/, code, c.inspect) }
    end

    first = concepts.first
    detail = RpmsRpc::Terminology.concept(first[:dts_id])
    assert_equal first.values_at(:concept_id, :dts_id, :fsn), detail.values_at(:concept_id, :dts_id, :fsn)
    assert_nil RpmsRpc::Terminology.concept("999999999")

    assert_includes RpmsRpc::Terminology.code_sets.map { |s| s[:id] }, RpmsRpc::Terminology::SNOMED_CT
  end

  private

  def refused_without_bstsrpc
    assert_raises(RpmsRpc::Client::RpcRefusedError) { RpmsRpc::Terminology.search("diabetes") }
  end
end
