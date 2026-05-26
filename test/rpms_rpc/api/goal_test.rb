# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/goal"

class GoalTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      # ORQQGO LIST — keyed by patient DFN, multi-line.
      m.seed_keyed_collection(:goal_list, "8791", [
        {
          ien: "701",
          goal_text: "Reduce A1C to <7.0",
          lifecycle_status: "active",
          achievement_status: "in-progress",
          category: "physiologic",
          priority: "high",
          start_date: nil,
          target_date: nil,
          status_date: nil,
          provider_duz: "301",
          provider_name: "PROVIDER,TEST",
          note: "Patient receptive to dietary changes"
        },
        {
          ien: "702",
          goal_text: "Walk 30 min/day",
          lifecycle_status: "",   # API should default to "active"
          achievement_status: nil,
          category: nil,
          priority: nil,
          start_date: nil,
          target_date: nil,
          status_date: nil,
          provider_duz: nil,
          provider_name: nil,
          note: nil
        }
      ])

      # ORQQGO GET — single-line response, keyed by IEN.
      m.seed(:goal_detail, "701", {
        goal_text: "Reduce A1C to <7.0",
        lifecycle_status: "active",
        achievement_status: "in-progress",
        category: "physiologic",
        priority: "high",
        start_date: nil,
        target_date: nil,
        status_date: nil,
        provider_duz: "301",
        provider_name: "PROVIDER,TEST",
        patient_dfn: 8791
      })

      # ORQQGO GET — multi-line response with prose note.
      m.seed_text(:goal_detail, "702",
        "Walk 30 min/day^^^^^^^^^^^8791\n" \
        "Started after 2026-03 visit.\n" \
        "Reassess at 90d.")

      m.seed(:goal_detail, "703_BLANK", {
        goal_text: "Blank-status goal",
        lifecycle_status: nil,
        achievement_status: nil,
        category: nil,
        priority: nil,
        start_date: nil,
        target_date: nil,
        status_date: nil,
        provider_duz: nil,
        provider_name: nil,
        patient_dfn: 8791
      })
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # === for_patient ==========================================================

  def test_for_patient_returns_goals
    goals = RpmsRpc::Goal.for_patient(8791)

    assert_kind_of Array, goals
    assert_equal 2, goals.length
    a1c = goals.find { |g| g[:goal_text] == "Reduce A1C to <7.0" }
    refute_nil a1c
    assert_equal "active",      a1c[:lifecycle_status]
    assert_equal "in-progress", a1c[:achievement_status]
    assert_equal "physiologic", a1c[:category]
    assert_equal "high",        a1c[:priority]
    assert_equal "301",         a1c[:provider_duz]
    assert_equal "PROVIDER,TEST", a1c[:provider_name]
    assert_equal "Patient receptive to dietary changes", a1c[:note]
  end

  def test_for_patient_defaults_lifecycle_status_when_blank
    goals = RpmsRpc::Goal.for_patient(8791)
    walk = goals.find { |g| g[:goal_text] == "Walk 30 min/day" }
    refute_nil walk
    assert_equal "active", walk[:lifecycle_status]
  end

  def test_for_patient_returns_empty_for_invalid_dfn
    assert_equal [], RpmsRpc::Goal.for_patient(nil)
    assert_equal [], RpmsRpc::Goal.for_patient("")
    assert_equal [], RpmsRpc::Goal.for_patient(0)
  end

  def test_for_patient_returns_empty_for_unknown_dfn
    assert_equal [], RpmsRpc::Goal.for_patient(999_999)
  end

  # === find =================================================================

  def test_find_returns_single_goal
    goal = RpmsRpc::Goal.find(701)

    refute_nil goal
    assert_equal 701,                  goal[:ien]
    assert_equal "Reduce A1C to <7.0", goal[:goal_text]
    assert_equal "active",             goal[:lifecycle_status]
    assert_equal "in-progress",        goal[:achievement_status]
    assert_equal 8791,               goal[:patient_dfn]
  end

  def test_find_joins_continuation_lines_into_note
    goal = RpmsRpc::Goal.find(702)
    refute_nil goal
    assert_equal "Walk 30 min/day", goal[:goal_text]
    assert_equal 8791,            goal[:patient_dfn]
    assert_equal "Started after 2026-03 visit.\nReassess at 90d.", goal[:note]
  end

  def test_find_defaults_lifecycle_status_when_blank
    goal = RpmsRpc::Goal.find("703_BLANK")
    refute_nil goal
    assert_equal "active", goal[:lifecycle_status]
  end

  def test_find_returns_nil_for_blank_or_nonpositive_ien
    assert_nil RpmsRpc::Goal.find(nil)
    assert_nil RpmsRpc::Goal.find("")
    assert_nil RpmsRpc::Goal.find(0)
    assert_nil RpmsRpc::Goal.find(-5)
  end

  def test_find_returns_nil_for_unknown_ien
    assert_nil RpmsRpc::Goal.find(999_998)
  end
end
