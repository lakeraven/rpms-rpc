# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/referral"

# Referral.for_patient answers for a patient instead of dying in M (#210).
#
# BMC SEARCH REFERRAL is SRCHREF^BMCRPC1(RSLT,PATIENT,REFPRVDR,STRTDATE,
# ENDDATE,RECNMBR,STATUS) (BMCRPC1.m:9). The routine reads +RECNMBR without
# $G (BMCRPC1.m:32), so a frame with the DFN alone failed on every build:
# SRCHREF+23^BMCRPC1, LVUNDEF RECNMBR (yotta-1016, 2026-10-16). The method now
# sends all six formals, the five filters empty.
#
# Reads only. A fresh container has no RCIS REFERRAL (#90001) on file, so the
# answer may be empty; what this proves is that the call answers, and that any
# row it does return belongs to the patient asked for.
class ReferralSearchLiveTest < LiveSpec::Test
  DFN = 4 # DEMO,PATIENT ONE on the pinned build (patient_live_test.rb)

  def test_for_patient_answers_with_that_patients_referrals
    rows = RpmsRpc::Referral.for_patient(DFN)

    assert_kind_of Array, rows
    rows.each { |row| assert_equal DFN, row[:patient_dfn], "for_patient(#{DFN}) returned #{row[:ien]}, another patient's referral" }
    puts "\n#{persona}: Referral.for_patient(#{DFN}) answered #{rows.size} referral(s)"
  end
end
