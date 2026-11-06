# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/ddr_fileman"
require "securerandom"

# Keeping a registered patient current (rpms-ux S-REG-20, S-REG-21): the
# record is read the way AG's client reads it (AGG BUILD WINDOW DISPLAY), an
# edit files through AG's own update (AGG UPDATE PATIENT) after AG's own
# checks (AGG WINDOW DATA VALIDATION), and every write is read back from
# FileMan (DDR GETS ENTRY DATA), not from the gem's answer.
#
# Each spec registers its own synthetic patient, so no seed patient is
# changed. There is no supported patient-delete RPC: discard the container.
class PatientRegistrationRecordLiveTest < LiveSpec::Test
  writes!

  IHS_PATIENT_FILE = "9000001"

  def register!(**extra)
    suffix = SecureRandom.hex(5).tr("0-9", "G-P").upcase
    attrs = { name_last: "ZZEDIT#{suffix}", name_first: "DEMO", dob: Date.new(1950, 1 + rand(12), 1 + rand(28)),
              sex: "F", ssn: "6660#{format('%05d', rand(100_000))}" }.merge(extra)
    result = RpmsRpc::Patient.register(attrs)
    assert result && result[:success], "could not register a synthetic patient: #{result.inspect}"
    [ result[:dfn], attrs ]
  end

  def fileman(file, dfn, fields)
    reply = RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{dfn},", fields: fields, flags: "I")
    refute_nil reply, "DDR GETS ENTRY DATA gave no reply"
    refute reply[:error], "FileMan refused the read of ##{file} #{dfn}"
    reply[:fields].transform_values { |f| f[:internal].to_s }
  end

  def name_changes(dfn)
    listed = RpmsRpc::DdrFileman.lister(file: "9000033", fields: ".01;.02", flags: "IP", xref: "C", from: (dfn - 1).to_s,
                                        part: dfn.to_s, max: "50")
    refute_nil listed, "DDR LISTER gave no reply"
    Array(listed[:rows] || listed[:entries])
  end

  def test_s_reg_20_1_the_record_reads_back_what_was_registered
    dfn, attrs = register!

    record = RpmsRpc::Patient.registration_record(dfn)

    assert_equal "#{attrs[:name_last]},DEMO", record[:name]
    assert_equal attrs[:dob], record[:dob]
    assert_equal({ internal: "F", external: "FEMALE" }, record[:sex])
    assert_equal attrs[:ssn], record[:ssn]
    assert_equal dfn.to_s, record[:hrn]
  end

  def test_s_reg_20_1_demographics_file_to_patient_and_ihs_patient
    dfn, = register!

    result = RpmsRpc::Patient.update(dfn, dob: Date.new(1951, 2, 3), sex: "M", marital_status: "2", religion: "1",
                                          birth_city: "SPRINGFIELD", birth_state: "27", employer: "1",
                                          employment_status: "FULL-TIME")

    assert_equal({ success: true, dfn: dfn }, result)
    assert_equal({ ".02" => "M", ".03" => "2510203", ".05" => "2", ".08" => "1", ".092" => "SPRINGFIELD", ".093" => "27" },
                 fileman("2", dfn, ".02;.03;.05;.08;.092;.093"))
    assert_equal({ ".19" => "1", ".21" => "1" }, fileman(IHS_PATIENT_FILE, dfn, ".19;.21"))
  end

  def test_s_reg_20_7_an_ssn_on_another_patient_is_refused_and_nothing_is_filed
    other, other_attrs = register!
    dfn, attrs = register!

    result = RpmsRpc::Patient.update(dfn, ssn: other_attrs[:ssn], marital_status: "2")

    assert_equal({ success: false, error: :agg_invalid, field: :ssn, message: "SSN already used by another patient." }, result)
    assert_equal({ ".05" => "", ".09" => attrs[:ssn] }, fileman("2", dfn, ".05;.09"))
    assert_equal other_attrs[:ssn], fileman("2", other, ".09")[".09"]
  end

  def test_s_reg_20_10_a_spelling_correction_changes_the_name_and_no_name_change_is_recorded
    dfn, attrs = register!
    before = name_changes(dfn)

    corrected = "#{attrs[:name_last]},DEMI"
    assert_equal({ success: true, dfn: dfn }, RpmsRpc::Patient.update(dfn, name: corrected))

    assert_equal corrected, fileman("2", dfn, ".01")[".01"]
    assert_equal before, name_changes(dfn)
  end

  def test_a_name_not_in_last_first_form_is_refused_with_ags_message
    dfn, attrs = register!

    result = RpmsRpc::Patient.update(dfn, name: "#{attrs[:name_last]} DEMO")

    assert_equal({ success: false, error: :agg_invalid, field: :name, message: "Name does not contain a comma" }, result)
    assert_equal "#{attrs[:name_last]},DEMO", fileman("2", dfn, ".01")[".01"]
  end

  def test_s_reg_21_1_the_address_and_home_phone_file_to_patient
    dfn, = register!

    result = RpmsRpc::Patient.update(dfn, address_line1: "12 EXAMPLE RD", city: "ANYWHERE", state: "27", zip: "59001",
                                          phone_home: "406-555-0142")

    assert_equal({ success: true, dfn: dfn }, result)
    assert_equal({ ".111" => "12 EXAMPLE RD", ".114" => "ANYWHERE", ".115" => "27", ".116" => "59001", ".131" => "406-555-0142" },
                 fileman("2", dfn, ".111;.114;.115;.116;.131"))
  end

  def test_s_reg_21_4_a_zip_that_is_not_5_or_9_digits_is_refused
    dfn, = register!

    result = RpmsRpc::Patient.update(dfn, zip: "5900", city: "ANYWHERE")

    assert_equal({ success: false, error: :agg_invalid, field: :zip, message: "Enter 5 or 9 digit zip code." }, result)
    assert_equal({ ".114" => "", ".116" => "" }, fileman("2", dfn, ".114;.116"))
  end

  def test_s_reg_21_5_email_files_to_ihs_patient_and_the_replaced_one_is_kept
    dfn, = register!
    assert RpmsRpc::Patient.update(dfn, email: "first@example.test")[:success]

    assert RpmsRpc::Patient.update(dfn, email: "second@example.test", phone_work: "406-555-0143", phone_other: "406-555-0144")[:success]

    assert_equal({ ".132" => "406-555-0143" }, fileman("2", dfn, ".132"))
    assert_equal({ "1801" => "406-555-0144", "1802" => "second@example.test" }, fileman(IHS_PATIENT_FILE, dfn, "1801;1802"))
    previous = RpmsRpc::DdrFileman.lister(file: "9000001.82", iens: ",#{dfn},", fields: ".02", flags: "IP", max: "10")
    refute_nil previous
    assert_includes previous.to_s, "first@example.test"
  end
end
