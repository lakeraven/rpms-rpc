# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient_selection"

# PatientSelection.find finds a patient the way VueCentric's patient selection
# does (BEHOPTPL), by whatever the clinician has in hand. The demo build's
# MOUSE,MICKEY M is DFN 3, HRN 1001, born 1910-02-14, SSN ending 9999. It reads
# only.
class PatientSelectionLiveTest < LiveSpec::Test
  def dfns(text) = RpmsRpc::PatientSelection.find(text).map { |row| row[:dfn] }

  def test_a_last_name_lists_the_patients_whose_names_begin_with_it
    rows = RpmsRpc::PatientSelection.find("MOUSE")

    assert_includes rows, { dfn: 3, name: "MOUSE,MICKEY M" }
    assert rows.all? { |row| row[:name].start_with?("MOUSE") }, rows.inspect
  end

  def test_a_whole_name_finds_that_patient
    assert_includes dfns("MOUSE,MICKEY M"), 3
  end

  def test_a_health_record_number_finds_the_patient
    assert_includes dfns("1001"), 3
  end

  def test_the_last_four_of_the_ssn_alone_or_after_the_initial_finds_the_patient
    assert_includes dfns("9999"), 3
    assert_includes dfns("M9999"), 3
  end

  def test_a_date_of_birth_as_typed_or_iso_finds_the_patient
    assert_includes dfns("2/14/1910"), 3
    assert_includes dfns("1910-02-14"), 3
  end

  def test_no_match_is_an_empty_list
    assert_equal [], RpmsRpc::PatientSelection.find("2/14/2010")
    assert_equal [], RpmsRpc::PatientSelection.find("ZZZZNOBODY")
  end
end
