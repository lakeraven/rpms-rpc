# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient"

# The banner's Patient Record Flags (rpms-rpc#526): the behavioral-health
# safety flag BEHOCACV CWAD reports as "F" and ORWPT CWAD does not. openrpms
# SEEDPRF assigns the stock national BEHAVIORAL flag to one panel patient
# (openrpms#1082).
class PatientFlagsLiveTest < LiveSpec::Test
  runs_as "PROV123"
  FLAGGED_DFN = 990_003 # CHARLIE,JORDAN, a synthetic panel patient
  UNFLAGGED_DFN = 990_004

  def test_a_flagged_patient_answers_the_active_national_flag
    assert_equal [ { name: "BEHAVIORAL", national: true } ], RpmsRpc::Patient.flags(FLAGGED_DFN)
  end

  def test_a_patient_with_no_flag_answers_nothing
    assert_empty RpmsRpc::Patient.flags(UNFLAGGED_DFN)
  end
end
