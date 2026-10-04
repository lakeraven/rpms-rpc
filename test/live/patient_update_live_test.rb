# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/ddr_fileman"

# RpmsRpc::Patient.update files PATIENT (#2) and IHS PATIENT (#9000001) fields
# with DDR FILER under the ^DPT(DFN) lock (Registration.update). Each spec
# files a value on a seed patient, reads it back through another path, and
# puts the patient back as it was. DDR FILER and DDR GETS ENTRY DATA are in
# CIAV VUECENTRIC, the option sign-on binds, for PROV123 and the programmer.
class PatientUpdateLiveTest < LiveSpec::Test
  writes!

  DFN = 990_031 # EMBER,AVERY, a synthetic seed patient
  IHS_PATIENT_FILE = "9000001"
  COMMUNITY = "1118"

  def test_update_files_a_patient_field_and_contact_reads_it_back
    before = RpmsRpc::Patient.contact(DFN)
    refute_nil before, "no telecom read for seed patient #{DFN}: is this the pinned build?"
    @restore = -> { RpmsRpc::Patient.update(DFN, patient_fields: { ".132" => before[:phone_work] || "@" }) }

    result = RpmsRpc::Patient.update(DFN, patient_fields: { ".132" => "406-555-0199" })

    assert_equal({ success: true, dfn: DFN }, result)
    assert_equal before.merge(phone_work: "406-555-0199"), RpmsRpc::Patient.contact(DFN)
  end

  def test_update_files_an_ihs_patient_field
    before = community
    refute_empty before.to_s, "seed patient #{DFN} has no community (#9000001 field #{COMMUNITY}) on this build"
    @restore = -> { RpmsRpc::Patient.update(DFN, ihs_fields: { COMMUNITY => before }) }

    result = RpmsRpc::Patient.update(DFN, ihs_fields: { COMMUNITY => "LIVE SPEC MESA" })

    assert_equal({ success: true, dfn: DFN }, result)
    assert_equal "LIVE SPEC MESA", community
  end

  # Email (.133) and cell phone (.134) file, but a #2 cross-reference run by
  # DIKC reads an undefined DFN and the filer reply is an M error.
  def test_update_files_email_and_cell_phone
    skip_tracked("#351", "filing #2 .133/.134 over DDR FILER raises <LVUNDEF> DFN in DIKC though the value files")

    before = RpmsRpc::Patient.contact(DFN)
    refute_nil before, "no telecom read for seed patient #{DFN}: is this the pinned build?"
    @restore = lambda do
      RpmsRpc::Patient.update(DFN, patient_fields: { ".133" => before[:email] || "@", ".134" => before[:phone_cell] || "@" })
    end

    result = RpmsRpc::Patient.update(DFN, patient_fields: { ".133" => "ember.avery@example.test", ".134" => "406-555-0198" })

    assert_equal({ success: true, dfn: DFN }, result)
    assert_equal before.merge(email: "ember.avery@example.test", phone_cell: "406-555-0198"), RpmsRpc::Patient.contact(DFN)
  end

  def teardown
    @restore&.call if client
  ensure
    super
  end

  private

  def community
    reply = RpmsRpc::DdrFileman.gets_entry(file: IHS_PATIENT_FILE, iens: "#{DFN},", fields: COMMUNITY, flags: "IE")
    refute_nil reply, "DDR GETS ENTRY DATA gave no reply"
    refute reply[:error], "no IHS PATIENT entry for seed patient #{DFN}"
    reply[:fields].dig(COMMUNITY, :external)
  end
end
