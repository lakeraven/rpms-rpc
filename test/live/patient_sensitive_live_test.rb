# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient"

# A sensitive record through the patient reads, as the provider
# (rpms-rpc#946). The gem reveals no more than each RPC answers and adds no
# masking of its own; each read says whether the record is sensitive, so the
# host runs the stock flow (DgSensitive.check_access: DG SENSITIVE RECORD
# ACCESS, its warning and its DG SECURITY LOG entry) before it shows one.
# TANGO,MARLOWE is a sensitive record on the demo build since
# bcer-9.0-20261124-60d39b6-ydb; MOUSE,MICKEY M is not. Reads only.
class PatientSensitiveLiveTest < LiveSpec::Test
  runs_as :provider

  SENSITIVE = 990_020 # TANGO,MARLOWE
  PLAIN = 3 # MOUSE,MICKEY M

  def test_a_sensitive_record_is_flagged_and_masked_only_where_the_rpc_masks_it
    found = RpmsRpc::Patient.find(SENSITIVE)
    assert_equal true, found[:sensitive], "ORWPT SELECT's SENSITIVE piece"
    assert_equal "*SENSITIVE*", found[:ssn], "ORWPT ID INFO masks the SSN, and its value is kept"
    assert_nil found[:dob], "ORWPT ID INFO masks the DOB, and its value is kept"

    banner = RpmsRpc::Patient.brief_header(SENSITIVE)
    assert_equal true, banner[:sensitive], "PTINFO's PTSEC code"
    assert_kind_of Date, banner[:dob], "BEHOPTCX PTINFO answers the DOB, and the gem does not hide it"
  end

  def test_a_record_that_is_not_sensitive_is_not_flagged
    found = RpmsRpc::Patient.find(PLAIN)
    assert_equal false, found[:sensitive]
    assert_match(/\A\d{9}\z/, found[:ssn], "the SSN is what ORWPT SELECT and ID INFO answer")
    assert_equal false, RpmsRpc::Patient.brief_header(PLAIN)[:sensitive]
  end
end
