# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/registration"

# Finding the patient before registering, as the front desk clerk
# (openrpms-ux S-REG-01) through AGG LOOKUP PATIENTS, the division-aware
# registration lookup, and AG's registration read. The demo build's
# MOUSE,MICKEY M is DFN 3, HRN 1001, born 1910-02-14. Reads only.
class PilotFindPatientLiveTest < LiveSpec::Test
  runs_as :front_desk_clerk
  proves "S-REG-01.1", "S-REG-01.2", "S-REG-01.7"

  DFN = 3

  # S-REG-01.1: by last name and by date of birth, the patient is listed
  # with the health record number, and the registration opens.
  def test_last_name_or_date_of_birth_lists_the_patient_with_the_hrn_and_the_registration_opens
    { "MOUSE" => "N", "02/14/1910" => "D" }.each do |text, type|
      row = RpmsRpc::Patient.lookup(text, type: type).find { |r| r[:dfn] == DFN }
      assert row, "#{text.inspect} (type #{type}) lists DFN #{DFN}"
      assert_equal "1001", row[:hrn]
      assert_nil row[:ssn], "the clerk lacks AGZVIEWSSN, so no SSN is returned"
    end

    record = RpmsRpc::Registration.record(DFN)
    assert_equal [ "MOUSE,MICKEY M", Date.new(1910, 2, 14) ], record.values_at(:name, :dob)
  end

  # S-REG-01.2: no patient matches, so the lookup answers no one, and a new
  # patient may be added.
  def test_no_match_lists_no_one
    assert_equal [], RpmsRpc::Patient.lookup("ZZZNOBODY#{rand(1000)}", type: "N")
  end

  # S-REG-01.7: an identifier that is not in PATIENT (#2) opens no record.
  def test_an_identifier_not_in_patient_opens_no_record
    assert_nil RpmsRpc::Registration.record(999_999_999)
  end
end
