# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/patient_selection"

# PatientSelection.find finds a patient the way VueCentric's patient selection
# does (BEHOPTPL), by whatever the clinician has in hand, and lists each with the
# identifiers BEHOPTCX PTINFO gives (S-CHT-01.1). The demo build's
# MOUSE,MICKEY M is DFN 3, HRN 1001, male, born 1910-02-14, SSN ending 9999. It
# reads only.
class PatientSelectionLiveTest < LiveSpec::Test
  runs_as :provider
  proves "S-CHT-01.1"
  MICKEY = { dfn: 3, name: "MOUSE,MICKEY M", dob: Date.new(1910, 2, 14), sex: "M", hrn: "1001", sensitive: false }.freeze
  def dfns(text) = RpmsRpc::PatientSelection.find(text).map { |row| row[:dfn] }

  def test_a_last_name_lists_the_patients_whose_names_begin_with_it
    rows = RpmsRpc::PatientSelection.find("MOUSE")

    assert_includes rows, MICKEY
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

  def test_every_lookup_lists_the_patient_with_date_of_birth_sex_and_hrn_and_no_ssn
    %w[MOUSE 1001 2/14/1910 9999 M9999].each do |query|
      rows = RpmsRpc::PatientSelection.find(query)

      assert_includes rows, MICKEY, "#{query} lists MOUSE,MICKEY M with his identifiers"
      rows.each do |row|
        assert_equal %i[dfn name dob sex hrn sensitive], row.keys, "#{query}: #{row.inspect}"
        assert_kind_of Date, row[:dob], "#{query}: #{row.inspect}"
        assert_includes %w[M F], row[:sex], "#{query}: #{row.inspect}"
      end
    end
  end

  # A sensitive record is listed with what PTINFO shows this user, the same
  # identifiers the chart banner reads, and flagged so the host runs the stock
  # warning before it opens the chart (#946). TANGO,MARLOWE is the demo build's
  # sensitive record.
  def test_a_sensitive_record_is_listed_with_what_ptinfo_shows_and_flagged
    row = RpmsRpc::PatientSelection.find("TANGO").find { |r| r[:dfn] == 990_020 }
    banner = RpmsRpc::Patient.brief_header(990_020)

    refute_nil row, "TANGO,MARLOWE is listed"
    assert_equal true, row[:sensitive]
    assert_equal banner.values_at(:dob, :sex, :mrn), row.values_at(:dob, :sex, :hrn)
  end

  def test_no_match_is_an_empty_list
    assert_equal [], RpmsRpc::PatientSelection.find("2/14/2010")
    assert_equal [], RpmsRpc::PatientSelection.find("ZZZZNOBODY")
  end
end
