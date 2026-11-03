# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient_profile"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/patient"

# RpmsRpc::PatientProfile files a patient's emergency contact, next of kin,
# languages and other names through AG's GUI windows (rpms-ux S-REG-08, S-REG-10,
# S-REG-12). Each spec writes to a synthetic seed patient and reads FileMan back
# through DDR GETS ENTRY DATA. A languages entry cannot be deleted through AG, so
# run on a disposable container.
class PatientProfileLiveTest < LiveSpec::Test
  writes!

  DFN = 990_008 # HOTEL,DREW, a synthetic seed patient
  SPOUSE = 22   # RELATIONSHIP (#9999999.36)
  FATHER = 1
  ENGLISH = 144 # LANGUAGE (#9999999.99)
  SPANISH = 531

  def fields(file, iens, list)
    reply = RpmsRpc::DdrFileman.gets_entry(file: file, iens: iens, fields: list, flags: "I")
    refute_nil reply, "DDR GETS ENTRY DATA gave no reply"
    refute reply[:error], "no #{file} entry #{iens}"
    reply[:fields].transform_values { |v| v[:internal] }
  end

  def test_s_reg_08_1_and_08_2_contacts_file_to_patient_and_a_new_name_clears_the_old_address
    clear_contacts
    result = RpmsRpc::PatientProfile.update_contact(DFN, :emergency, name: "LIVE,CONTACT", relationship: SPOUSE,
                                                                     address_line1: "1 TEST ST", city: "ANYTOWN",
                                                                     zip: "12345", phone: "555-555-0100")
    assert_equal({ success: true, dfn: DFN }, result)
    assert RpmsRpc::PatientProfile.update_contact(DFN, :next_of_kin, name: "LIVE,KIN", relationship: FATHER,
                                                                     phone: "555-555-0101")[:success]

    assert_equal({ ".331" => "LIVE,CONTACT", ".333" => "1 TEST ST", ".336" => "ANYTOWN", ".339" => "555-555-0100",
                   ".211" => "LIVE,KIN", ".219" => "555-555-0101" },
                 fields("2", "#{DFN},", ".331;.333;.336;.339;.211;.219"))
    assert_equal({ "3102" => SPOUSE.to_s, "2802" => FATHER.to_s }, fields("9000001", "#{DFN},", "3102;2802"))

    assert RpmsRpc::PatientProfile.update_contact(DFN, :emergency, name: "OTHER,PERSON")[:success]
    assert_equal({ ".331" => "OTHER,PERSON", ".333" => "", ".336" => "", ".339" => "" },
                 fields("2", "#{DFN},", ".331;.333;.336;.339"))
  ensure
    clear_contacts if client
  end

  def test_s_reg_08_3_and_08_4_refusals_file_nothing
    clear_contacts
    assert_equal({ success: false, error: :invalid, field: :name, message: "No space after the comma" },
                 RpmsRpc::PatientProfile.update_contact(DFN, :emergency, name: "LIVE, CONTACT"))
    assert_equal :name_required, RpmsRpc::PatientProfile.update_contact(DFN, :emergency, phone: "555-555-0100")[:error]

    assert_equal({ ".331" => "", ".339" => "" }, fields("2", "#{DFN},", ".331;.339"))
  end

  def test_s_reg_10_1_languages_file_a_new_dated_entry_and_keep_the_earlier
    assert RpmsRpc::PatientProfile.record_languages(DFN, primary: ENGLISH, proficiency: "VW", preferred: ENGLISH)[:success]
    result = RpmsRpc::PatientProfile.record_languages(DFN, primary: SPANISH, interpreter: "Y", preferred: SPANISH,
                                                           proficiency: "NW", others: [ ENGLISH ])
    assert result[:success], result.inspect
    entry = result[:entry]

    assert_equal({ ".02" => SPANISH.to_s, ".03" => "Y", ".04" => SPANISH.to_s, ".06" => "NW" },
                 fields("9000001.86", "#{entry},#{DFN},", ".02;.03;.04;.06"))
    assert_equal ENGLISH.to_s, fields("9000001.8605", "#{ENGLISH},#{entry},#{DFN},", ".01")[".01"]
    assert_equal ENGLISH.to_s, fields("9000001.86", "#{entry - 1},#{DFN},", ".02")[".02"], "the earlier entry is kept"
    assert_equal [ ENGLISH ], RpmsRpc::PatientProfile.languages(DFN)[:others].map { |o| o[:ien] }
  end

  def test_s_reg_12_2_to_12_4_other_names_add_search_and_remove
    added = RpmsRpc::PatientProfile.add_alias(DFN, "LIVEALIASQX,DREW")
    assert added[:success], added.inspect
    assert_equal "LIVEALIASQX,DREW", fields("2.01", "#{added[:ien]},#{DFN},", ".01")[".01"]
    assert_includes RpmsRpc::Patient.lookup("LIVEALIASQX").map { |row| row[:dfn] }, DFN

    assert_equal "No space after the comma", RpmsRpc::PatientProfile.add_alias(DFN, "LIVE, ALIAS")[:message]
    assert_equal :invalid, RpmsRpc::PatientProfile.add_alias(DFN, "AB")[:error]

    assert RpmsRpc::PatientProfile.remove_alias(DFN, added[:ien])[:success]
    refute_includes RpmsRpc::PatientProfile.aliases(DFN).map { |a| a[:ien] }, added[:ien]
  end

  def test_relationship_language_and_state_look_ups_answer_by_name
    assert_includes RpmsRpc::PatientProfile.relationships("SPO"), { ien: SPOUSE, name: "SPOUSE" }
    assert_includes RpmsRpc::PatientProfile.language_lookup("ENGL"), { ien: ENGLISH, name: "ENGLISH" }
    assert(RpmsRpc::PatientProfile.states("WASH").any? { |s| s[:name] == "WASHINGTON" })
  end

  private

  def clear_contacts
    %i[emergency next_of_kin].each do |kind|
      next if RpmsRpc::PatientProfile.contacts(DFN)[kind].to_h[:name].to_s.empty?

      assert RpmsRpc::PatientProfile.update_contact(DFN, kind, name: "", relationship: "")[:success]
    end
  end
end
