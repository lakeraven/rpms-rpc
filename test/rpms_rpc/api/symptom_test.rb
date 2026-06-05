# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/symptom"

class SymptomTest < Minitest::Test
  def teardown
    RpmsRpc.reset!
  end

  def test_search_returns_matching_symptoms
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:symptom_search, "rash", [
        { ien: 1, name: "Rash", snomed_code: "271807003" },
        { ien: 2, name: "Rash, generalized", snomed_code: "247409008" }
      ])
    end

    rows = RpmsRpc::Symptom.search("rash")
    assert_equal 2, rows.length
    assert_equal "271807003", rows.first[:snomed_code]
  end

  def test_search_dispatches_orwdal32_symptoms
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:symptom_search, "itching", [])
    end
    RpmsRpc::Symptom.search("itching")
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWDAL32 SYMPTOMS" }
    assert_equal [ "itching" ], call[:params]
  end

  def test_search_blank_returns_empty
    assert_equal [], RpmsRpc::Symptom.search(nil)
    assert_equal [], RpmsRpc::Symptom.search("")
    assert_equal [], RpmsRpc::Symptom.search("   ")
  end

  def test_defaults_parses_the_typed_tree_into_categories_with_items
    RpmsRpc.mock! do |m|
      m.seed_text(:symptom_defaults, "", <<~TREE.chomp)
        ~Reactions
        iD^Drug
        iF^Food
        iO^Other
        ~Top Ten
        iO^Common Drug Reactions
        ~Observ/Hist
        io^Observed
      TREE
    end

    categories = RpmsRpc::Symptom.defaults

    assert_equal [ "Reactions", "Top Ten", "Observ/Hist" ], categories.map { |c| c[:category] }
    assert_equal [
      { code: "D", label: "Drug" },
      { code: "F", label: "Food" },
      { code: "O", label: "Other" }
    ], categories.first[:items]
    assert_equal [ { code: "o", label: "Observed" } ], categories.last[:items]
  end

  def test_defaults_returns_empty_when_response_is_blank
    RpmsRpc.mock! do |m|
      m.seed_text(:symptom_defaults, "", "")
    end
    assert_equal [], RpmsRpc::Symptom.defaults
  end

  def test_defaults_dispatches_orwdal32_def
    RpmsRpc.mock! do |m|
      m.seed_text(:symptom_defaults, "", "~Reactions\niD^Drug")
    end
    RpmsRpc::Symptom.defaults
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWDAL32 DEF" }
    refute_nil call
  end
end
