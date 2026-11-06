# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/pov"

# The rows are BEHOENCX VISITLST and BGOVPOV RECENT replies captured from
# bcer-9.0-20261029-7c3119b-ydb (DFN 2).
class EncounterVisitsTest < Minitest::Test
  VISIT_ROWS = [
    "6;3261005.1;A;12^DEMO PRIMARY CARE^3261005.1^AMBULATORY^0^206^PROFILE,MD^1",
    "6;3260825.09;A;1^DEMO PRIMARY CARE^3260825.09^AMBULATORY^0^206^PROFILE,MD^1"
  ].freeze
  POV_ROW = "08/25/2026^000012^DEMO IHS CLINIC^I10.^Essential (primary) hypertension^ESSENTIAL HYPERTENSION^2^1^508014^0^^^^"
  SNOMED_POV_ROW = "10/05/2026^000012^DEMO IHS CLINIC^N39.0^Urinary tract infection, site not specified^" \
                   "Acute urinary tract infection | ^11^12^517599^0^^^431309003^"

  def teardown
    RpmsRpc.reset!
  end

  def visit_rows(rows)
    RpmsRpc::DataMapper[:encounter_visit_list].parse_many(rows)
  end

  def test_a_visit_row_is_split_into_its_identifiers
    row = visit_rows(VISIT_ROWS).last

    assert_equal "6;3260825.09;A;1", row[:visit_string]
    assert_equal "DEMO PRIMARY CARE", row[:location]
    assert_equal "AMBULATORY", row[:category]
    assert_equal 206, row[:provider_ien]
    assert_equal "PROFILE,MD", row[:provider]
    assert_equal Time.new(2026, 8, 25, 9, 0, 0).to_i, row[:datetime].to_i
  end

  def test_visits_asks_for_the_whole_history_without_appointments
    RpmsRpc.mock! { |m| m.seed_text(:encounter_visit_list, "2", VISIT_ROWS.join("\n")) }

    visits = RpmsRpc::Encounter.visits(2)

    call = RpmsRpc.client.received_calls.last
    assert_equal "BEHOENCX VISITLST", call[:rpc]
    assert_equal [ "2", "2000101", "3991231", "", "X", "1" ], call[:params].to_a
    assert_equal [ 12, 1 ], visits.map { |visit| visit[:visit_ien] }
    assert_equal [ 6, 6 ], visits.map { |visit| visit[:location_ien] }
    assert_equal %w[A A], visits.map { |visit| visit[:service_category] }
    refute visits.first.key?(:visit_string)
  end

  def test_a_pending_appointment_has_no_visit_ien_and_is_not_a_visit
    pending_row = visit_rows([ "6;3261105.09;A^DEMO PRIMARY CARE^3261105.09^Pending Check-In" ]).first

    assert_nil RpmsRpc::Encounter.send(:visit_with_identifiers, pending_row)
  end

  def test_a_pov_row_names_its_visit_and_its_diagnosis
    row = RpmsRpc::DataMapper[:patient_pov_list].parse_many([ POV_ROW ]).first

    assert_equal "2", row[:ien]
    assert_equal "1", row[:visit_ien]
    assert_equal "I10.", row[:icd_code]
    assert_equal "Essential (primary) hypertension", row[:icd_name]
    assert_equal "ESSENTIAL HYPERTENSION", row[:narrative]
    assert_equal "08/25/2026", row[:visit_date]
  end

  def test_a_pov_row_keeps_its_snomed_concept
    row = RpmsRpc::DataMapper[:patient_pov_list].parse_many([ SNOMED_POV_ROW ]).first

    assert_equal "431309003", row[:snomed_ct]
  end
end
