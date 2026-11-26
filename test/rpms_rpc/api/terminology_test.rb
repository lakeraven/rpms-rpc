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

  def replay(flow, slug: SLUG)
    @client = Replay.new(flow ? CapturedReplies.flow_script(slug, flow) : {})
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def assert_sent_under_bstsrpc(flow, slug: SLUG)
    sent = @client.calls.reject { |c| c[:rpc] == :create_context }
    assert_equal CapturedReplies.flow_calls(slug, flow), sent.map { |c| [ c[:rpc], c[:params] ] }
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
  # TAHEAD^BSTSRPC1 (test/fixtures/captured_replies/bsts-type-ahead.yml): the
  # header, then one word per row, sent as the routine's four parameters.
  def type_ahead_replay(name)
    raw = CapturedReplies.raw("bsts-type-ahead", name)
    @client = Replay.new("BSTS SEARCH TYPE AHEAD" => [ raw ])
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def type_ahead_inputs(name)
    CapturedReplies.file("bsts-type-ahead").fetch("captures").find { |c| c["name"] == name }.fetch("inputs")
  end

  def test_type_ahead_offers_the_words_that_start_with_the_text
    type_ahead_replay("words")

    assert_equal [ "Diabetes", "Diabetes-deafness", "Diabetes-nephrosis", "Diabetes-pancreatic", "Diabetes-related" ],
                 RpmsRpc::Terminology.type_ahead("diab", max: 5)
    sent = @client.calls.reject { |c| c[:rpc] == :create_context }
    assert_equal [ [ "BSTS SEARCH TYPE AHEAD", type_ahead_inputs("words") ] ], sent.map { |c| [ c[:rpc], c[:params] ] }
    assert_equal [ "BSTSRPC" ], sent.map { |c| c[:context] }
  end

  def test_a_prefix_no_term_holds_offers_no_words
    type_ahead_replay("no_words")

    assert_equal [], RpmsRpc::Terminology.type_ahead("zzqxv")
  end

  def test_a_blank_or_caret_prefix_is_refused_before_the_wire
    replay(nil)

    [ "", "  ", "a^b" ].each do |text|
      assert_raises(ArgumentError, text.inspect) { RpmsRpc::Terminology.type_ahead(text) }
    end
    assert_empty @client.calls
  end

  # SUBSET^BSTSRPC (test/fixtures/captured_replies/bsts-subsets-icd9.yml):
  # the local cache's subsets, a problem-list subset shown without "SRCH ".
  PICKS = "bsts-subsets-icd9"

  def test_subsets_list_the_pick_lists_the_cache_holds
    replay("subsets", slug: PICKS)

    subsets = RpmsRpc::Terminology.subsets

    assert_operator subsets.size, :>, 300
    assert_includes subsets, { name: "PICK Behavioral Health", display_name: "PICK Behavioral Health" }
    assert_includes subsets, { name: "SRCH Common Terms", display_name: "Common Terms" }
    assert_sent_under_bstsrpc("subsets", slug: PICKS)
  end

  def test_problem_list_subsets_are_the_srch_ones
    replay("problem_list_subsets", slug: PICKS)

    subsets = RpmsRpc::Terminology.subsets(problem_list: true)

    refute_empty subsets
    assert(subsets.all? { |s| s[:name] == "SRCH #{s[:display_name]}" }, subsets.inspect)
    assert_sent_under_bstsrpc("problem_list_subsets", slug: PICKS)
  end

  # ICD2SMD^BSTSRPC: one row per mapped concept; its relations and subsets
  # pieces are not returned.
  def test_from_icd9_answers_the_concepts_the_code_maps_to
    replay("from_icd9", slug: PICKS)

    assert_equal [ { concept_id: "309597007", description_id: "453054011",
                     preferred_term: "Foot abnormality - diabetes-related", icd: [ "250.00" ] } ],
                 RpmsRpc::Terminology.from_icd9("250.00")
    assert_sent_under_bstsrpc("from_icd9", slug: PICKS)
  end

  def test_a_code_the_cache_maps_to_nothing_is_empty
    replay("from_icd9_none", slug: PICKS)

    assert_equal [], RpmsRpc::Terminology.from_icd9("296.20")
    assert_sent_under_bstsrpc("from_icd9_none", slug: PICKS)
  end

  def test_from_icd9_narrowed_to_a_subset_the_concept_is_not_in_is_empty
    replay("from_icd9_in_subset", slug: PICKS)

    assert_equal [], RpmsRpc::Terminology.from_icd9("250.00", subsets: [ "SRCH Diabetes" ])
    assert_sent_under_bstsrpc("from_icd9_in_subset", slug: PICKS)
  end

  # ICD2SMD^BSTSRPC reads a leading "?" as a text search and "|" as its
  # piece separator.
  def test_from_icd9_refuses_what_is_not_an_icd9_code_before_the_wire
    replay(nil)

    [ "", "?diabetes", "250.00|x", "E11.9x", "250^1" ].each do |code|
      assert_raises(ArgumentError, code.inspect) { RpmsRpc::Terminology.from_icd9(code) }
    end
    assert_raises(ArgumentError) { RpmsRpc::Terminology.from_icd9("250.00", subsets: [ "a|b" ]) }
    assert_empty @client.calls
  end

  # GET^BSTSUPRF and SET^BSTSUPRF (test/fixtures/captured_replies/bsts-user-prefs.yml),
  # recorded in order on one user: none saved, a save, the row read back, a
  # refused count, a reset, none saved again.
  PREFS = "bsts-user-prefs"

  def test_a_user_who_saved_no_preferences_has_none
    replay("preferences_none", slug: PREFS)

    assert_nil RpmsRpc::Terminology.preferences
    assert_sent_under_bstsrpc("preferences_none", slug: PREFS)
  end

  def test_update_preferences_files_every_field
    replay("save", slug: PREFS)

    assert RpmsRpc::Terminology.update_preferences(search_type: :synonym, max: 100, parents_children: true)
    assert_sent_under_bstsrpc("save", slug: PREFS)
  end

  def test_saved_preferences_read_back_typed
    replay("preferences_saved", slug: PREFS)

    assert_equal({ search_type: :synonym, max: 100, parents_children: true, autocomplete_disabled: false },
                 RpmsRpc::Terminology.preferences)
    assert_sent_under_bstsrpc("preferences_saved", slug: PREFS)
  end

  def test_a_value_bsts_refuses_raises_with_its_text
    replay("save_refused", slug: PREFS)

    error = assert_raises(RpmsRpc::Terminology::BstsError) { RpmsRpc::Terminology.update_preferences(max: 75) }
    assert_equal "Invalid Record Count Value", error.package_message
    assert_kind_of RpmsRpc::Client::RpcError, error
    assert_sent_under_bstsrpc("save_refused", slug: PREFS)
  end

  def test_reset_deletes_the_saved_preferences
    replay("reset", slug: PREFS)

    assert RpmsRpc::Terminology.delete_preferences
    assert_sent_under_bstsrpc("reset", slug: PREFS)
  end

  def test_update_preferences_refuses_a_search_type_bsts_has_no_letter_for
    replay(nil)

    assert_raises(ArgumentError) { RpmsRpc::Terminology.update_preferences(search_type: :prefix) }
    assert_raises(ArgumentError) { RpmsRpc::Terminology.update_preferences(max: "50|1") }
    assert_empty @client.calls
  end

  # SELECT^BSTSRPC1: the header and "1", queued or not.
  def test_record_selection_reports_the_pick
    replay("record_selection", slug: PREFS)

    assert RpmsRpc::Terminology.record_selection("73211009", description_id: "121589010", subset: "SRCH Diabetes")
    assert_sent_under_bstsrpc("record_selection", slug: PREFS)
  end

  # A blank concept id: the routine sets BMXSEC and answers nothing, which
  # must not read as success. The API refuses it before the wire; a reply
  # with no header raises.
  def test_a_reply_with_no_header_is_not_success
    @client = Replay.new("BSTS LOG SELECTED CONCEPT" => [ CapturedReplies.raw(PREFS, "log_blank_concept") ])
    RpmsRpc.configure { |cfg| cfg.client = @client }

    assert_raises(ArgumentError) { RpmsRpc::Terminology.record_selection("") }
    assert_empty @client.calls
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Terminology.record_selection("73211009") }
  end
end
