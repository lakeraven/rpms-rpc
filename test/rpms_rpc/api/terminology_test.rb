# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/terminology"
require_relative "../captured_replies"

# RpmsRpc::Terminology over IHS Standard Terminology (BSTS), option BSTSRPC
# (rpms-rpc#916). The replies are the build's
# (test/fixtures/captured_replies/bsts-terminology.yml), recorded as flows as
# the provider test role on its local BSTS cache and replayed through
# CiaClient; each test checks the gem sent exactly the recorded calls, under
# BSTSRPC, and handed the caller's option back.
class TerminologyTest < Minitest::Test
  SLUG = "bsts-terminology"

  class Replay < CapturedReplies::ReplayCiaClient
    def call_rpc_raw(rpc_name, *params)
      super.tap { @calls.last[:context] = current_context }
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow)
    @client = Replay.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {})
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def assert_sent_under_bstsrpc(flow)
    sent = @client.calls.reject { |c| c[:rpc] == :create_context }
    assert_equal CapturedReplies.flow_calls(SLUG, flow), sent.map { |c| [ c[:rpc], c[:params] ] }
    assert(sent.all? { |c| c[:context] == "BSTSRPC" }, "every BSTS call runs under BSTSRPC: #{sent.map { |c| c[:context] }}")
    assert_equal "CIAV VUECENTRIC", @client.current_context, "the caller's option is handed back"
  end

  # SEARCH^BSTSRPC: one row per concept, its ICD maps $C(28)-joined.
  def test_search_returns_concepts_with_their_terms_and_icd_maps
    replay("search")

    concepts = RpmsRpc::Terminology.search("diabetes", max: 25)

    assert_equal 25, concepts.size
    kidney = concepts.find { |c| c[:dts_id] == "1119000077" }
    assert_equal({ concept_id: "771000119108", fsn: "Chronic kidney disease due to type 2 diabetes mellitus (disorder)",
                   icd: [ "E11.22", "N18.9" ] }, kidney.slice(:concept_id, :fsn, :icd),
                 "two ICD maps, split where the routine joined them")
    assert_equal "Diabetes type 2 with kidney disease", kidney[:term]
    assert(concepts.all? { |c| c[:concept_id].match?(/\A\d+\z/) && !c[:term].empty? })
    assert_sent_under_bstsrpc("search")
  end

  def test_a_search_that_matches_nothing_is_empty
    replay("search_none")

    assert_equal [], RpmsRpc::Terminology.search("zzzqqq")
    assert_sent_under_bstsrpc("search_none")
  end

  # DETAIL^BSTSRPC1 by the BSTS concept IEN a search gave.
  def test_concept_detail_carries_its_fsn_and_icd_maps
    replay("concept")

    concept = RpmsRpc::Terminology.concept("1119000077")

    assert_equal({ term: "Chronic kidney disease due to type 2 diabetes mellitus",
                   preferred_term: "Chronic kidney disease due to type 2 diabetes mellitus",
                   concept_id: "771000119108", dts_id: "1119000077",
                   fsn: "Chronic kidney disease due to type 2 diabetes mellitus (disorder)", icd: [ "E11.22", "N18.9" ],
                   prompt_laterality: false, default_status: "Chronic", requires_episodicity: false,
                   prompt_abnormal_finding: false, selectable: true }, concept)
    assert_sent_under_bstsrpc("concept")
  end

  def test_an_ien_no_concept_has_is_nil
    replay("concept_unknown")

    assert_nil RpmsRpc::Terminology.concept("999999999")
    assert_sent_under_bstsrpc("concept_unknown")
  end

  def test_code_sets_list_the_local_cache
    replay("code_sets")

    sets = RpmsRpc::Terminology.code_sets

    assert_includes sets, { id: 36, name: "SNOMED CT US Edition" }
    assert_includes sets, { id: 5140, name: "ICD-10-CM" }
    assert_sent_under_bstsrpc("code_sets")
  end

  # SEARCH^BSTSRPC reads "|" as its piece separator, so text carrying one
  # would shift every piece after it.
  def test_text_that_would_break_the_search_frame_is_refused_before_the_wire
    replay(nil)

    [ "", "  ", "a|b", "a^b" ].each do |text|
      assert_raises(ArgumentError, text.inspect) { RpmsRpc::Terminology.search(text) }
    end
    assert_raises(ArgumentError) { RpmsRpc::Terminology.concept("73211009; K ^XUSEC") }
    assert_empty @client.calls
  end
end
