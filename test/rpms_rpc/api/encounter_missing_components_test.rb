# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/encounter"

# BEHOENCX CHKVISIT rows: satisfied messages must not appear in missing_components (#563).
class EncounterMissingComponentsTest < Minitest::Test
  VISIT_IEN = 1
  DFN = 2

  SATISFIED_MESSAGES = [
    "Visit has POV",
    "Visit has E&M code",
    "E&M code not required.",
    "Provider does not require E&M code"
  ].freeze

  MISSING_MESSAGES = [
    "Notification was delivered",
    "Notification exists",
    "Notification is disabled"
  ].freeze

  NOT_CHECKED_MESSAGES = [
    "Visit has no note",
    "No primary provider",
    "Bad visit specifier"
  ].freeze

  def setup
    RpmsRpc.mock! do |m|
      m.seed(:encounter_visit, VISIT_IEN.to_s, {
        location_ien: 6,
        datetime_raw: "3260825.09",
        service_category: "A",
        patient_dfn: DFN,
        visit_id: "",
        locked: false
      })
      m.seed(:encounter_fetch, DFN.to_s, {
        location_name: "DEMO PRIMARY CARE",
        location_abbrev: "DPC",
        room_bed: "",
        provider_ien: 12,
        provider_name: "DEMO,DOCTOR",
        visit_ien: VISIT_IEN,
        visit_id: "",
        locked: false
      })
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def missing_components_for(rows)
    RpmsRpc.client.seed_keyed_collection(:encounter_chkvisit, VISIT_IEN.to_s, rows)
    RpmsRpc::Encounter.open(DFN, VISIT_IEN)[:missing_components]
  end

  SATISFIED_MESSAGES.each do |message|
    define_method(:"test_drops_satisfied_message_#{message.gsub(/\W+/, '_')}") do
      list = missing_components_for([ { component: "POV", message: message } ])
      assert_empty list, "satisfied message #{message.inspect} must be dropped"
    end
  end

  def test_drops_satisfied_message_with_surrounding_whitespace
    list = missing_components_for([ { component: "POV", message: " Visit has POV " } ])
    assert_empty list
  end

  MISSING_MESSAGES.each do |message|
    define_method(:"test_keeps_missing_message_#{message.gsub(/\W+/, '_')}") do
      list = missing_components_for([ { component: "NOTIF", message: message } ])
      assert_equal [ { component: "NOTIF", message: message } ], list
    end
  end

  NOT_CHECKED_MESSAGES.each do |message|
    define_method(:"test_keeps_not_checked_message_#{message.gsub(/\W+/, '_')}") do
      component = message == "Visit has no note" ? "E&M" : "POV"
      list = missing_components_for([ { component: component, message: message } ])
      assert_equal [ { component: component, message: message } ], list
    end
  end

  def test_keeps_unrecognised_message_fail_closed
    list = missing_components_for([ { component: "X", message: "Something new" } ])
    assert_equal [ { component: "X", message: "Something new" } ], list
  end

  def test_live_mix_keeps_only_em_row
    list = missing_components_for([
      { component: "POV", message: "Visit has POV" },
      { component: "E&M", message: "Visit has no note" }
    ])
    assert_equal [ { component: "E&M", message: "Visit has no note" } ], list
  end

  def test_keeps_lookalike_that_is_not_exact_satisfied_text
    list = missing_components_for([ { component: "POV", message: "Visit has POV pending" } ])
    assert_equal [ { component: "POV", message: "Visit has POV pending" } ], list
  end
end
