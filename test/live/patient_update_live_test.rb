# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/ddr_fileman"

# RpmsRpc::Patient.update files through AG: AGG UPDATE PATIENT (UPD^AGGPTUPD),
# one call per AG window, under AGG LOCK PATIENT, all bound to AGGRPC by the
# gem (rpms-rpc#381). Each spec updates a seed patient, reads the value back
# through Patient.contact (DDR GETS ENTRY DATA, in CIAV VUECENTRIC), and puts
# the patient back as it was.
#
# What UPD^AGGPTUPD writes besides the value, and so what is asserted here:
# #9000001 .03 (last registration update, set to DT) and .12 (by whom, DUZ)
# at AGGPTUPD.m:131-132, and the previous email into 9000001.82 when the
# email changes (EML^AGGUL1, AGGUL1.m:318-331). EDIT^AGGEXPRT (AGGPTUPD.m:133)
# stages the HL7 export in ^XTMP("AGHL7"), which no FileMan read reaches, so
# it is not asserted. UPD writes no ^AGPATCH stamp (only roll-and-scroll AG
# does, AGMAN.m:28), so none is asserted (rpms-rpc#381).
class PatientUpdateLiveTest < LiveSpec::Test
  writes!

  DFN = 990_031 # EMBER,AVERY, a synthetic seed patient
  IHS_PATIENT_FILE = "9000001"

  def test_update_files_a_work_phone_and_contact_reads_it_back
    before = contact!
    @restore = -> { RpmsRpc::Patient.update(DFN, phone_work: before[:phone_work].to_s) }

    result = RpmsRpc::Patient.update(DFN, phone_work: "406-555-0199")

    assert_equal({ success: true, dfn: DFN }, result)
    assert_equal before.merge(phone_work: "406-555-0199"), RpmsRpc::Patient.contact(DFN)
  end

  # Email is AG's #9000001 1802 (Address window AGGPTEML); #2 .133 is not
  # written (rpms-rpc#351 cannot occur on this path).
  def test_update_files_email_where_ag_keeps_it
    before = contact!
    @restore = -> { RpmsRpc::Patient.update(DFN, email: before[:email].to_s) }

    result = RpmsRpc::Patient.update(DFN, email: "ember.avery@example.test")

    assert_equal({ success: true, dfn: DFN }, result)
    assert_equal before.merge(email: "ember.avery@example.test"), RpmsRpc::Patient.contact(DFN)
  end

  def test_update_stamps_the_last_registration_update_and_who
    before = contact!
    @restore = -> { RpmsRpc::Patient.update(DFN, phone_home: before[:phone_home].to_s) }

    assert RpmsRpc::Patient.update(DFN, phone_home: "406-555-0101")[:success]

    reply = RpmsRpc::DdrFileman.gets_entry(file: IHS_PATIENT_FILE, iens: "#{DFN},", fields: ".03;.12", flags: "I")
    refute_nil reply, "DDR GETS ENTRY DATA gave no reply"
    refute reply[:error], "no IHS PATIENT entry for seed patient #{DFN}"
    stamped = reply[:fields].dig(".03", :internal).to_i
    assert_includes fileman_dates_around_today, stamped, "#9000001 .03 is DT after the update (AGGPTUPD.m:131)"
    assert_equal client.duz.to_s, reply[:fields].dig(".12", :internal), "#9000001 .12 is the DUZ (AGGPTUPD.m:131)"
  end

  def test_cell_phone_is_refused_before_anything_is_sent
    assert_raises(RpmsRpc::Registration::AttributeNotOfferedError) do
      RpmsRpc::Patient.update(DFN, phone_cell: "406-555-0198")
    end
  end

  def teardown
    @restore&.call if client
  ensure
    super
  end

  private

  def contact!
    before = RpmsRpc::Patient.contact(DFN)
    refute_nil before, "no telecom read for seed patient #{DFN}: is this the pinned build?"
    before
  end

  # The server's DT may be a day off the runner's clock around midnight.
  def fileman_dates_around_today
    (-1..1).map do |offset|
      d = Date.today + offset
      ((d.year - 1700) * 10_000) + (d.month * 100) + d.day
    end
  end
end
