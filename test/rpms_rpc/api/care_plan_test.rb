# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/care_plan"

class CarePlanTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      # ORQQCP LIST — keyed by patient DFN, multi-line, full 13-field shape.
      m.seed_keyed_collection(:care_plan_list, "8791", [
        {
          ien: "101",
          title: "Diabetes Management",
          status: "active",
          intent: "plan",
          category: "assess-plan",
          start_date: nil,
          end_date: nil,
          author_duz: "301",
          author_name: "PROVIDER,TEST",
          goal_iens: "201;202",
          activity: "Monitor A1C quarterly",
          description: "Patient managing T2DM with metformin",
          note: nil
        },
        {
          ien: "102",
          title: "Hypertension Control",
          status: "",         # empty → API should default to "active"
          intent: "",         # empty → API should default to "plan"
          category: "",       # empty → API should default to "assess-plan"
          start_date: nil,
          end_date: nil,
          author_duz: "301",
          author_name: "PROVIDER,TEST",
          goal_iens: nil,
          activity: nil,
          description: nil,
          note: nil
        }
      ])

      # ORQQCP GET — keyed by IEN. First line is field-based; subsequent lines
      # are free-text description joined by the API module.
      #
      # Field positions 0..11 (from mappings):
      #   title^status^intent^category^start^end^author_duz^author_name^goal_iens^activity^(unused)^patient_dfn
      m.seed(:care_plan_detail, "101", {
        title: "Diabetes Management",
        status: "active",
        intent: "plan",
        category: "assess-plan",
        start_date: nil,
        end_date: nil,
        author_duz: "301",
        author_name: "PROVIDER,TEST",
        goal_iens: "201;202",
        activity: "Monitor A1C quarterly",
        patient_dfn: "8791"
      })
      # 102 returns a multi-line text response: first line field-based,
      # remaining lines are the prose description.
      RpmsRpc.client.instance_variable_get(:@text_blobs).tap { |tb| tb ||= {} }
      # Use seed_text-equivalent direct injection alongside the existing
      # field-based record: when both exist the @lines / @text_blobs maps
      # are checked first. We model the multi-line response by overriding
      # via the @text_blobs path that MockClient already supports for the
      # same key — that returns an Array split on \n.
      m.seed_text(:care_plan_detail, "102",
        "Hypertension Control^^^^^^^^^^^8791\n" \
        "Patient on lisinopril 10mg daily.\n" \
        "BP target <130/80.")

      m.seed(:care_plan_detail, "999_BLANK_FIELDS", {
        title: "Mostly Blank",
        status: nil,
        intent: nil,
        category: nil,
        start_date: nil,
        end_date: nil,
        author_duz: nil,
        author_name: nil,
        goal_iens: nil,
        activity: nil,
        patient_dfn: "8791"
      })
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # === for_patient ==========================================================

  def test_for_patient_returns_care_plans
    plans = RpmsRpc::CarePlan.for_patient(8791)

    assert_kind_of Array, plans
    assert_equal 2, plans.length
    dm = plans.find { |p| p[:title] == "Diabetes Management" }
    refute_nil dm
    assert_equal "active", dm[:status]
    assert_equal "plan",   dm[:intent]
    assert_equal "301",    dm[:author_duz]
    assert_equal "PROVIDER,TEST", dm[:author_name]
    assert_equal "201;202", dm[:goal_iens]
    assert_equal "Monitor A1C quarterly", dm[:activity]
    assert_equal "Patient managing T2DM with metformin", dm[:description]
  end

  def test_for_patient_applies_defaults_for_blank_status_intent_category
    plans = RpmsRpc::CarePlan.for_patient(8791)
    htn = plans.find { |p| p[:title] == "Hypertension Control" }
    refute_nil htn
    assert_equal "active",      htn[:status]
    assert_equal "plan",        htn[:intent]
    assert_equal "assess-plan", htn[:category]
  end

  def test_for_patient_returns_empty_for_invalid_dfn
    assert_equal [], RpmsRpc::CarePlan.for_patient(nil)
    assert_equal [], RpmsRpc::CarePlan.for_patient("")
    assert_equal [], RpmsRpc::CarePlan.for_patient(0)
  end

  def test_for_patient_returns_empty_for_unknown_dfn
    assert_equal [], RpmsRpc::CarePlan.for_patient(999999)
  end

  # === find =================================================================

  def test_find_returns_single_plan_for_single_line_response
    plan = RpmsRpc::CarePlan.find(101)

    refute_nil plan
    assert_equal 101,                    plan[:ien]
    assert_equal "Diabetes Management",  plan[:title]
    assert_equal "active",               plan[:status]
    assert_equal "plan",                 plan[:intent]
    assert_equal "assess-plan",          plan[:category]
    assert_equal "301",                  plan[:author_duz]
    assert_equal "PROVIDER,TEST",        plan[:author_name]
    assert_equal "201;202",              plan[:goal_iens]
    assert_equal "Monitor A1C quarterly", plan[:activity]
    assert_equal "8791",                 plan[:patient_dfn]
  end

  def test_find_joins_continuation_lines_into_description
    plan = RpmsRpc::CarePlan.find(102)

    refute_nil plan
    assert_equal "Hypertension Control", plan[:title]
    assert_equal "8791",                 plan[:patient_dfn]
    assert_equal "Patient on lisinopril 10mg daily.\nBP target <130/80.", plan[:description]
  end

  def test_find_applies_defaults_for_blank_status_intent_category
    plan = RpmsRpc::CarePlan.find("999_BLANK_FIELDS")
    refute_nil plan
    assert_equal "active",      plan[:status]
    assert_equal "plan",        plan[:intent]
    assert_equal "assess-plan", plan[:category]
  end

  def test_find_returns_nil_for_blank_ien
    assert_nil RpmsRpc::CarePlan.find(nil)
    assert_nil RpmsRpc::CarePlan.find("")
  end

  def test_find_returns_nil_for_unknown_ien
    assert_nil RpmsRpc::CarePlan.find(999_998)
  end
end
