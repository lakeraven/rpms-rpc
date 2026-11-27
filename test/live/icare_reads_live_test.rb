# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/coverage"

# iCare's reads, as the care manager: an ordinary iCare user who holds BQIRPC,
# the one option that registers iCare's BQI RPCs, and no keys. Each read files
# nothing.
#
# openrpms#1401 seeds the care manager's account (PROFILE,CM); until a release
# carries it the role's row is pending, so this spec skips by that issue
# before it signs on.
class IcareReadsLiveTest < LiveSpec::Test
  runs_as :care_manager
  needs "BQIRPC", tracked: "openrpms#1401"

  DFN = 2 # a synthetic patient every demo build seeds

  # BQI PATIENT INSURANCE (GET^BQIPTINS): the patient's active coverage, under
  # BQIRPC. The reply opens with BQIPTINS's typed header, which for_patient
  # checks; a patient with no coverage on file answers the header alone.
  def test_a_patients_insurance_reads_under_bqirpc
    got = RpmsRpc::Coverage.for_patient(DFN)

    refute_nil got, "BQI PATIENT INSURANCE gave no reply with BQIPTINS's typed header for DFN #{DFN}"
    got[:entries].each do |row|
      refute_empty row[:coverage].to_s, "an insurance row names its coverage: #{row.inspect}"
    end
  end
end
