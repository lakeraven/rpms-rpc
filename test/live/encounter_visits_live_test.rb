# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/pov"

# A patient's visits (BEHOENCX VISITLST) and diagnoses (BGOVPOV RECENT) on seed
# patient DFN 2, whose visit 1 carries the panel's POVs.
class EncounterVisitsLiveTest < LiveSpec::Test
  DFN = 2
  VISIT_IEN = 1
  LOCATION_IEN = 6

  def test_the_seed_patient_has_visit_one_with_its_location_and_time
    visit = RpmsRpc::Encounter.visits(DFN).find { |row| row[:visit_ien] == VISIT_IEN }

    refute_nil visit, "visit #{VISIT_IEN} must list for DFN #{DFN}"
    assert_equal LOCATION_IEN, visit[:location_ien]
    assert_equal "A", visit[:service_category]
    assert_kind_of Time, visit[:datetime]
    refute_empty visit[:location]
  end

  def test_visits_are_newest_first_and_each_has_an_ien
    visits = RpmsRpc::Encounter.visits(DFN)

    assert visits.all? { |row| row[:visit_ien].positive? }
    assert_equal visits.map { |row| row[:datetime] }.sort.reverse, visits.map { |row| row[:datetime] }
  end

  def test_each_diagnosis_names_a_visit_of_the_patient
    visits = RpmsRpc::Encounter.visits(DFN).map { |visit| visit[:visit_ien].to_s }
    povs = RpmsRpc::Pov.for_patient(DFN)

    refute_empty povs, "the seed patient carries POVs"
    assert povs.all? { |row| visits.include?(row[:visit_ien]) }, povs.inspect
    assert povs.all? { |row| row[:icd_code].to_s.match?(/\A[A-Z]\d/) }, povs.inspect
    assert povs.all? { |row| row[:visit_date].to_s.match?(%r{\A\d\d/\d\d/\d{4}\z}) }, povs.inspect
  end

  def test_a_patient_with_no_visits_has_no_diagnoses
    assert_empty RpmsRpc::Pov.for_patient(3)
  end
end
