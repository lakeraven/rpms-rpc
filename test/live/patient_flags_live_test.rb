# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient"

# The banner's Patient Record Flags (rpms-rpc#526): the behavioral-health
# safety flag BEHOCACV CWAD reports as "F" and ORWPT CWAD does not. rpms-ops
# SEEDPRF assigns the stock national BEHAVIORAL flag to one panel patient
# (rpms-ops#1082); the pin predates it until #639.
class PatientFlagsLiveTest < LiveSpec::Test
  FLAGGED_DFN = 990_003 # CHARLIE,JORDAN, a synthetic panel patient
  UNFLAGGED_DFN = 990_004
  BUILD_BEFORE_THE_SEED = "bcer-9.0-20261012-e7923a4-ydb"

  def test_a_flagged_patient_answers_the_active_national_flag
    flags = RpmsRpc::Patient.flags(FLAGGED_DFN)
    if flags.empty? && LiveSpec.build_label.start_with?(BUILD_BEFORE_THE_SEED)
      skip_tracked("#639", "the pinned build seeds no record flag")
    end

    assert_equal [ { name: "BEHAVIORAL", national: true } ], flags
  end

  def test_a_patient_with_no_flag_answers_nothing
    assert_empty RpmsRpc::Patient.flags(UNFLAGGED_DFN)
  end
end
