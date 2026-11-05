# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/encounter"

# BEHOENCX CHKVISIT rows: satisfied messages must not appear in missing_components (#563).
class EncounterMissingComponentsTest < Minitest::Test
  VISIT_IEN = 1
  DFN = 2

  POV_SATISFIED = "Visit has POV"
  EM_SATISFIED = "Visit has E&M code"

  SATISFIED_ROWS = [
    [ "POV", POV_SATISFIED ],
    [ "E&M", EM_SATISFIED ],
    [ "E&M", "E&M code not required." ],
    [ "E&M", "Provider does not require E&M code" ]
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

  def open_encounter(chkvisit_rows)
    RpmsRpc.client.seed_keyed_collection(:encounter_chkvisit, VISIT_IEN.to_s, chkvisit_rows)
    RpmsRpc::Encounter.open(DFN, VISIT_IEN)
  end

  def missing_components_for(rows)
    open_encounter(rows)[:missing_components]
  end

  def satisfied_row_for(component)
    case component
    when "POV" then { component: "POV", message: POV_SATISFIED }
    when "E&M" then { component: "E&M", message: EM_SATISFIED }
    else
      raise ArgumentError, "no satisfied pairing for #{component.inspect}"
    end
  end

  def with_both_components_present(*rows)
    pov = rows.find { |r| r[:component] == "POV" }
    em = rows.find { |r| r[:component] == "E&M" }
    out = rows.dup
    out << satisfied_row_for("POV") unless pov
    out << satisfied_row_for("E&M") unless em
    out
  end

  SATISFIED_ROWS.each do |component, message|
    define_method(:"test_drops_satisfied_message_#{message.gsub(/\W+/, '_')}") do
      row = { component: component, message: message }
      other = satisfied_row_for(component == "POV" ? "E&M" : "POV")
      list = missing_components_for([ row, other ])
      assert_empty list, "satisfied message #{message.inspect} must be dropped"
    end
  end

  def test_drops_satisfied_message_with_surrounding_whitespace
    list = missing_components_for([
      { component: "POV", message: " Visit has POV " },
      satisfied_row_for("E&M")
    ])
    assert_empty list
  end

  def test_both_components_satisfied_yields_empty_missing_components
    list = missing_components_for([
      satisfied_row_for("POV"),
      satisfied_row_for("E&M")
    ])
    assert_empty list
  end

  def test_missing_components_nil_when_chkvisit_empty
    result = open_encounter([])
    refute_nil result
    assert_equal VISIT_IEN, result[:visit_ien]
    assert_equal DFN, result[:patient_dfn]
    assert_nil result[:missing_components]
  end

  def test_missing_components_nil_when_only_pov_row
    result = open_encounter([ { component: "POV", message: "Visit has POV pending" } ])
    refute_nil result
    assert_nil result[:missing_components]
  end

  def test_missing_components_nil_when_only_em_row
    result = open_encounter([ { component: "E&M", message: "Visit has no note" } ])
    refute_nil result
    assert_nil result[:missing_components]
  end

  def test_keeps_cross_component_satisfied_text_on_pov_row
    list = missing_components_for(with_both_components_present(
      { component: "POV", message: "Visit has E&M code" }
    ))
    assert_equal [ { component: "POV", message: "Visit has E&M code" } ], list
  end

  def test_keeps_cross_component_satisfied_text_on_em_row
    list = missing_components_for(with_both_components_present(
      { component: "E&M", message: "Visit has POV" }
    ))
    assert_equal [ { component: "E&M", message: "Visit has POV" } ], list
  end

  MISSING_MESSAGES.each do |message|
    define_method(:"test_keeps_missing_message_#{message.gsub(/\W+/, '_')}") do
      row = { component: "NOTIF", message: message }
      list = missing_components_for(with_both_components_present(row))
      assert_equal [ row ], list
    end
  end

  NOT_CHECKED_MESSAGES.each do |message|
    define_method(:"test_keeps_not_checked_message_#{message.gsub(/\W+/, '_')}") do
      component = message == "Visit has no note" ? "E&M" : "POV"
      row = { component: component, message: message }
      list = missing_components_for(with_both_components_present(row))
      assert_equal [ row ], list
    end
  end

  def test_keeps_unrecognised_message_fail_closed
    row = { component: "X", message: "Something new" }
    list = missing_components_for(with_both_components_present(row))
    assert_equal [ row ], list
  end

  def test_live_mix_keeps_only_em_row
    list = missing_components_for([
      { component: "POV", message: "Visit has POV" },
      { component: "E&M", message: "Visit has no note" }
    ])
    assert_equal [ { component: "E&M", message: "Visit has no note" } ], list
  end

  def test_keeps_lookalike_that_is_not_exact_satisfied_text
    list = missing_components_for(with_both_components_present(
      { component: "POV", message: "Visit has POV pending" }
    ))
    assert_equal [ { component: "POV", message: "Visit has POV pending" } ], list
  end
end
