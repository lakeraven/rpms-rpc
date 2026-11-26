# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/terminology"

# RpmsRpc::Terminology on a real build (rpms-rpc#916, #963): SNOMED CT search,
# type-ahead, concept detail, code sets, subsets and ICD-9 maps from the local
# BSTS cache, under BSTSRPC.
# The provider's row holds BSTSRPC; the front desk clerk's does not, and the
# broker refuses it the option, which raises rather than reading as no
# concepts. Reads only.
class TerminologyLiveTest < LiveSpec::Test
  runs_as :provider, :front_desk_clerk

  def test_search_then_detail_then_code_sets
    return refused_without_bstsrpc { RpmsRpc::Terminology.search("diabetes") } if role == :front_desk_clerk

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

  # The words VueCentric's problem picker offers as the user types, before a
  # search: each starts with what was typed, and a prefix no term holds
  # answers none.
  def test_type_ahead_offers_words_that_start_with_the_text
    return refused_without_bstsrpc { RpmsRpc::Terminology.type_ahead("diab") } if role == :front_desk_clerk

    words = RpmsRpc::Terminology.type_ahead("diab", max: 5)
    refute_empty words
    assert_operator words.size, :<=, 5
    words.each { |w| assert w.downcase.start_with?("diab"), words.inspect }
    assert_empty RpmsRpc::Terminology.type_ahead("zzqxv")
  end

  # The pick lists VueCentric's picker offers, and a search narrowed to one:
  # the problem list's subsets are the SRCH ones, and a search in SRCH
  # Common Terms answers fewer concepts than the default problem-list search.
  def test_subsets_list_the_pick_lists_and_a_search_narrows_to_one
    return refused_without_bstsrpc { RpmsRpc::Terminology.subsets } if role == :front_desk_clerk

    names = RpmsRpc::Terminology.subsets.map { |s| s[:name] }
    assert_includes names, "PICK Behavioral Health"
    assert_includes names, "SRCH Common Terms"

    problem_list = RpmsRpc::Terminology.subsets(problem_list: true)
    refute_empty problem_list
    assert(problem_list.all? { |s| s[:name] == "SRCH #{s[:display_name]}" }, problem_list.inspect)

    narrowed = RpmsRpc::Terminology.search("depression", subsets: [ "SRCH Common Terms" ], max: 200)
    refute_empty narrowed
    assert_operator narrowed.size, :<, RpmsRpc::Terminology.search("depression", max: 200).size
  end

  # An ICD-9-CM code the cache maps answers its SNOMED CT concepts; one it
  # maps to none answers [], not an error, and the stack has no
  # terminology server to fall back to.
  def test_from_icd9_maps_a_code_to_its_snomed_concepts
    return refused_without_bstsrpc { RpmsRpc::Terminology.from_icd9("250.00") } if role == :front_desk_clerk

    concepts = RpmsRpc::Terminology.from_icd9("250.00")
    refute_empty concepts
    concepts.each do |c|
      assert_match(/\A\d+\z/, c[:concept_id], c.inspect)
      refute_empty c[:preferred_term], c.inspect
      assert_includes c[:icd], "250.00", c.inspect
    end
    assert_empty RpmsRpc::Terminology.from_icd9("296.20")
  end

  private

  def refused_without_bstsrpc(&)
    assert_raises(RpmsRpc::Client::RpcRefusedError, &)
  end
end
