# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/symptom"
require_relative "../captured_replies"

# Symptom reads the ORWDAL32 SYMPTOMS and ORWDAL32 DEF replies a fresh
# rpms-ydb container sent (test/fixtures/captured_replies/symptom.yml),
# replayed through CiaClient.
class SymptomTest < Minitest::Test
  SLUG = "symptom"
  SEARCH = "ORWDAL32 SYMPTOMS"
  DEF = "ORWDAL32 DEF"

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def capture(name) = CapturedReplies.raw(SLUG, name)

  def test_search_returns_the_page_of_symptoms_after_from
    replay(SEARCH => [ capture("from_rash") ])

    rows = RpmsRpc::Symptom.search("RASH")

    assert_equal 44, rows.length
    assert_equal({ ien: 378, name: "RECTAL HEMORRHAGE", preferred_name: nil }, rows.first.slice(:ien, :name, :preferred_name))
    synonym = rows.find { |r| r[:ien] == 78 }
    assert_equal "ERYTHEMA", synonym[:preferred_name], "a synonym row names its preferred symptom"
  end

  def test_search_sends_from_and_the_forward_direction
    client = replay(SEARCH => [ capture("from_rash") ])
    RpmsRpc::Symptom.search("RASH")

    # SYMPTOMS(Y,FROM,DIR) (ORWDAL32.m:61): DIR is the $O direction (#259).
    assert_equal [ { rpc: SEARCH, params: [ "RASH", "1" ] } ], client.calls
  end

  def test_search_past_the_last_symptom_is_empty
    replay(SEARCH => [ capture("past_the_end") ])

    assert_equal [], RpmsRpc::Symptom.search("ZZZZZZ")
  end

  def test_search_blank_returns_empty_without_a_call
    client = replay({})

    assert_equal [], RpmsRpc::Symptom.search(nil)
    assert_equal [], RpmsRpc::Symptom.search("")
    assert_equal [], RpmsRpc::Symptom.search("   ")
    assert_empty client.calls
  end

  def test_defaults_parses_the_typed_tree_into_categories_with_items
    client = replay(DEF => [ capture("defaults") ])

    categories = RpmsRpc::Symptom.defaults

    assert_equal [ "Allergy Types", "Reactions", "Nature of Reaction", "Top Ten", "Observ/Hist", "Severity" ],
                 categories.map { |c| c[:category] }
    assert_equal({ code: "D", label: "Drug" }, categories.first[:items].first)
    assert_equal [ { code: "o", label: "Observed" }, { code: "h", label: "Historical" } ],
                 categories.find { |c| c[:category] == "Observ/Hist" }[:items]
    assert_equal 10, categories.find { |c| c[:category] == "Top Ten" }[:items].size
    assert_equal [ { rpc: DEF, params: [] } ], client.calls
  end
end
