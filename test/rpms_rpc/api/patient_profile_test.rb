# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/patient_profile"

# RpmsRpc::PatientProfile: the emergency contact, next of kin, languages and
# other names, through AG's GUI windows. Reply layouts are the ones captured
# live on bcer-9.0-20261029-7c3119b-ydb as PROFILE,REG; all data synthetic.
class PatientProfileTest < Minitest::Test
  PP = RpmsRpc::PatientProfile
  FS = "\x1c"
  RS = "\x1e"
  US = "\x1f"
  DFN = 990_007

  EC_HEADER = "T00035AGGECNME^T00020AGGECPHN^T00040AGGECREL^T00030AGGECAD1^T00030AGGECAD2^T00030AGGECAD3^" \
              "T00030AGGECCTY^T00030AGGECSTE^T00015AGGECZIP^T00020AGGECWPH^T00030AGGECORL"
  NK_HEADER = EC_HEADER.gsub("AGGEC", "AGGNK")
  UPDATE_OK = "I00010RESULT^T01024ERROR^T01024OTHER_PARMS#{RS}1^^#{RS}#{US}"
  LOCK_OK = "I00010RESULT^T00080MESSAGE#{RS}1^#{RS}#{US}"
  VALID = "I00010RESULT^T00100MSG^T00001HANDLER^I00010IEN^T00008CODE^T00100REVALIDATE#{RS}1^^^^^#{RS}#{US}"

  def setup
    @mock = RpmsRpc.mock!
    @mock.seed(:agg_lock_patient, DFN.to_s, LOCK_OK)
    @mock.seed(:agg_unlock_patient, DFN.to_s, LOCK_OK)
  end

  def teardown
    RpmsRpc.reset!
  end

  def calls(rpc) = @mock.received_calls.select { |c| c[:rpc] == rpc }

  def seed_display(window, header, row = nil)
    @mock.seed(:agg_build_window_display, window, "#{header}#{RS}#{row ? "#{row}#{RS}" : ''}#{US}")
  end

  def refusal(message)
    "I00010RESULT^T00100MSG^T00001HANDLER^I00010IEN^T00008CODE^T00100REVALIDATE#{RS}-1^#{message}^^^^#{RS}#{US}"
  end

  # -- contacts ---------------------------------------------------------------

  def test_contacts_reads_both_windows_with_pointers_split
    seed_display(PP::EMERGENCY_WINDOW, EC_HEADER, "DOE,JANE^555-555-0100^22#{FS}SPOUSE^1 MAIN ST^^^ANYTOWN^#{FS}^12345^^")
    seed_display(PP::NEXT_OF_KIN_WINDOW, NK_HEADER)

    result = PP.contacts(DFN)

    assert_equal({ name: "DOE,JANE", relationship: { ien: 22, name: "SPOUSE" }, other_relationship: "",
                   address_line1: "1 MAIN ST", address_line2: "", address_line3: "", city: "ANYTOWN", state: nil,
                   zip: "12345", phone: "555-555-0100", phone_work: "" }, result[:emergency])
    assert_equal({}, result[:next_of_kin])
  end

  def test_contacts_is_nil_when_rpms_does_not_answer
    assert_nil PP.contacts(DFN)
  end

  # -- update_contact -----------------------------------------------------------

  def test_s_reg_08_1_a_contact_is_filed_through_the_window_under_the_lock
    @mock.seed(:agg_window_validation, PP::EMERGENCY_WINDOW, VALID)
    @mock.seed(:agg_update_patient, PP::EMERGENCY_WINDOW, UPDATE_OK)

    result = PP.update_contact(DFN, :emergency, name: "doe,jane ", relationship: 22, address_line1: "1 MAIN ST",
                                                zip: "12345", phone: "555-555-0100")

    assert_equal({ success: true, dfn: DFN }, result)
    sent = calls("AGG UPDATE PATIENT").first[:params]
    assert_equal [ PP::EMERGENCY_WINDOW, DFN.to_s,
                   "AGGECNME=DOE,JANE#{FS}AGGECREL=22#{FS}AGGECAD1=1 MAIN ST#{FS}AGGECZIP=12345#{FS}AGGECPHN=555-555-0100" ], sent
    assert_equal %w[AGG\ LOCK\ PATIENT AGG\ UPDATE\ PATIENT AGG\ UNLOCK\ PATIENT],
                 @mock.received_calls.map { |c| c[:rpc] }.grep(/LOCK|UPDATE/)
  end

  def test_s_reg_08_1_next_of_kin_uses_its_own_window_and_parameters
    @mock.seed(:agg_window_validation, PP::NEXT_OF_KIN_WINDOW, VALID)
    @mock.seed(:agg_update_patient, PP::NEXT_OF_KIN_WINDOW, UPDATE_OK)

    assert PP.update_contact(DFN, :next_of_kin, name: "DOE,JOHN", phone_work: "555-555-0102")[:success]

    assert_equal "AGGNKNME=DOE,JOHN#{FS}AGGNKWPH=555-555-0102", calls("AGG UPDATE PATIENT").first[:params][2]
  end

  # AG's own name check runs before anything is filed, and its message is the answer.
  def test_s_reg_08_3_a_name_ag_refuses_files_nothing_and_carries_ags_message
    @mock.seed(:agg_window_validation, PP::EMERGENCY_WINDOW, refusal("No space after the comma"))

    result = PP.update_contact(DFN, :emergency, name: "DOE, JANE")

    assert_equal({ success: false, error: :invalid, field: :name, message: "No space after the comma" }, result)
    assert_equal [ PP::EMERGENCY_WINDOW, "AGGECNME=DOE, JANE#{FS}DFN=#{DFN}" ], calls("AGG WINDOW DATA VALIDATION").first[:params]
    assert_empty calls("AGG UPDATE PATIENT")
  end

  def test_s_reg_08_3_a_name_shorter_than_the_window_allows_is_refused_before_rpms_is_asked
    result = PP.update_contact(DFN, :emergency, name: "AB")

    assert_equal :invalid, result[:error]
    assert_equal :name, result[:field]
    assert_empty @mock.received_calls
  end

  def test_s_reg_08_4_other_fields_with_no_name_on_file_are_refused
    seed_display(PP::EMERGENCY_WINDOW, EC_HEADER)

    result = PP.update_contact(DFN, :emergency, relationship: 22, phone: "555-555-0100")

    assert_equal :name_required, result[:error]
    assert_match(/'EMERGENCY CONTACT' name must be specified/, result[:message])
    assert_empty calls("AGG UPDATE PATIENT")
  end

  def test_s_reg_08_4_clearing_the_name_while_giving_other_fields_is_refused
    result = PP.update_contact(DFN, :next_of_kin, name: "", phone: "555-555-0100")

    assert_equal :name_required, result[:error]
    assert_match(/'NEXT OF KIN' name/, result[:message])
  end

  def test_other_fields_alone_file_when_a_name_is_on_file
    seed_display(PP::EMERGENCY_WINDOW, EC_HEADER, "DOE,JANE^^^^^^^^^^")
    @mock.seed(:agg_update_patient, PP::EMERGENCY_WINDOW, UPDATE_OK)

    assert PP.update_contact(DFN, :emergency, city: "ANYTOWN")[:success]
  end

  def test_a_zip_ag_refuses_is_refused_with_its_message
    @mock.seed(:agg_window_validation, PP::EMERGENCY_WINDOW, refusal("Enter numbers for zip code."))

    seed_display(PP::EMERGENCY_WINDOW, EC_HEADER, "DOE,JANE^^^^^^^^^^")

    result = PP.update_contact(DFN, :emergency, zip: "ABCDE")

    assert_equal({ success: false, error: :invalid, field: :zip, message: "Enter numbers for zip code." }, result)
  end

  def test_unknown_fields_are_refused_before_anything_is_sent
    assert_raises(ArgumentError) { PP.update_contact(DFN, :emergency, email: "x@example.test") }
    assert_raises(ArgumentError) { PP.update_contact(DFN, :guardian, name: "DOE,JANE") }
    assert_empty @mock.received_calls
  end

  # -- languages ----------------------------------------------------------------

  OTHER_PATIENT_HEADER = "T00030AGETH^T00030AGRACE^T00040AGGLGPRI^T00007AGGINTRP^T01024OTHLNG^T00015AGGLGPRF^" \
                         "T00015AGGLGEPF^D00015AGGLGDT"

  def test_languages_reads_the_latest_entry_and_its_other_languages
    seed_display(PP::OTHER_PATIENT_WINDOW, OTHER_PATIENT_HEADER,
                 "^^531#{FS}SPANISH^Y#{FS}YES^^531#{FS}SPANISH^NW#{FS}NOT WELL^NOV 3,2026")
    @mock.seed(:agg_patient_languages, DFN.to_s, "T00040AGGLGOTH^I00010LGIEN#{RS}144#{FS}ENGLISH^144#{RS}#{US}")

    assert_equal({ date: "NOV 3,2026", primary: { ien: 531, name: "SPANISH" }, preferred: { ien: 531, name: "SPANISH" },
                   interpreter: "Y", proficiency: "NW", others: [ { ien: 144, name: "ENGLISH" } ] }, PP.languages(DFN))
  end

  def test_s_reg_10_1_languages_file_a_new_entry_then_its_other_languages
    @mock.seed(:agg_update_patient, PP::OTHER_PATIENT_WINDOW, "I00010RESULT^T01024ERROR^T01024OTHER_PARMS#{RS}1^^AGGLNG=4#{RS}#{US}")
    # ULNG copied 532 from the previous entry; 144 is wanted, 532 is not.
    @mock.seed(:agg_patient_languages, DFN.to_s, "T00040AGGLGOTH^I00010LGIEN#{RS}532#{FS}SPOKANE^532#{RS}#{US}")
    @mock.seed(:agg_update_special_multiples, PP::OTHER_LANGUAGES_WINDOW, "I00010RESULT^T01024ERROR#{RS}1^#{RS}#{US}")

    result = PP.record_languages(DFN, primary: 531, interpreter: "Y", preferred: 531, proficiency: "NW", others: [ 144 ],
                                      english_ien: 144)

    assert_equal({ success: true, dfn: DFN, entry: 4 }, result)
    assert_equal [ PP::OTHER_PATIENT_WINDOW, DFN.to_s,
                   "AGGLGPRI=531#{FS}AGGINTRP=YES#{FS}AGGLGPRF=531#{FS}AGGLGEPF=NOT WELL" ], calls("AGG UPDATE PATIENT").first[:params]
    assert_equal [ [ PP::OTHER_LANGUAGES_WINDOW, DFN.to_s, "4", "A", "AGGLGOTH=144" ],
                   [ PP::OTHER_LANGUAGES_WINDOW, DFN.to_s, "4", "D", "AGGLGOTH=532" ] ],
                 calls("AGG UPDATE SPECIAL MULTIPLES").map { |c| c[:params] }
  end

  def test_s_reg_10_3_a_primary_language_other_than_english_needs_the_interpreter_answer
    result = PP.record_languages(DFN, primary: 531, preferred: 531, english_ien: 144)

    assert_equal({ success: false, error: :invalid, field: :interpreter,
                   message: "is required when the primary language is not English" }, result)
    assert_empty @mock.received_calls
  end

  def test_s_reg_10_2_english_needs_a_proficiency
    assert_equal :proficiency, PP.record_languages(DFN, primary: 144, english_ien: 144)[:field]
    assert_equal :proficiency, PP.record_languages(DFN, primary: 531, interpreter: "N", others: [ 144 ], english_ien: 144)[:field]
    assert_empty @mock.received_calls
  end

  def test_a_new_entry_that_rpms_does_not_name_is_not_success
    @mock.seed(:agg_update_patient, PP::OTHER_PATIENT_WINDOW, UPDATE_OK)

    result = PP.record_languages(DFN, primary: 144, proficiency: "VW", english_ien: 144)

    refute result[:success]
    assert_empty calls("AGG UPDATE SPECIAL MULTIPLES")
  end

  def test_an_other_language_rpms_refuses_is_partial
    @mock.seed(:agg_update_patient, PP::OTHER_PATIENT_WINDOW, "I00010RESULT^T01024ERROR^T01024OTHER_PARMS#{RS}1^^AGGLNG=2#{RS}#{US}")
    @mock.seed(:agg_patient_languages, DFN.to_s, "T00040AGGLGOTH^I00010LGIEN#{RS}#{US}")
    @mock.seed(:agg_update_special_multiples, PP::OTHER_LANGUAGES_WINDOW, "I00010RESULT^T01024ERROR#{RS}-1^NOT FILED#{RS}#{US}")

    result = PP.record_languages(DFN, primary: 144, proficiency: "VW", others: [ 531 ], english_ien: 144)

    assert_equal({ success: false, error: :partial, entry: 2, message: "NOT FILED" }, result)
  end

  # -- other names ----------------------------------------------------------------

  def test_aliases_lists_the_multiple
    @mock.seed(:agg_window_multiple, PP::ALIASES_WINDOW,
               "T00035AGGPTALS^I00010RIEN#{RS}OLDNAME,ROBIN^1#{RS}SECOND,ROBIN^2#{RS}#{US}")

    assert_equal [ { ien: 1, name: "OLDNAME,ROBIN" }, { ien: 2, name: "SECOND,ROBIN" } ], PP.aliases(DFN)
    assert_equal [ PP::ALIASES_WINDOW, ".01", DFN.to_s, "" ], calls("AGG BUILD WINDOW MULTIPLE").first[:params]
  end

  def test_s_reg_12_2_an_other_name_is_checked_then_added
    @mock.seed(:agg_window_validation, PP::ALIASES_WINDOW, VALID)
    @mock.seed(:agg_update_aliases, DFN.to_s, "I00010RESULT^T01024ERROR^I00010RIEN#{RS}1^^3#{RS}#{US}")

    assert_equal({ success: true, ien: 3 }, PP.add_alias(DFN, "oldname,robin"))
    assert_equal [ DFN.to_s, "A", "", "AGGPTALS=OLDNAME,ROBIN" ], calls("AGG UPDATE ALIASES").first[:params]
  end

  def test_s_reg_12_3_an_other_name_out_of_format_or_length_is_refused
    @mock.seed(:agg_window_validation, PP::ALIASES_WINDOW, refusal("No space after the comma"))

    assert_equal "No space after the comma", PP.add_alias(DFN, "OLD, NAME")[:message]
    assert_equal :invalid, PP.add_alias(DFN, "AB")[:error]
    assert_equal :invalid, PP.add_alias(DFN, "#{'A' * 20},#{'B' * 20}")[:error]
    assert_empty calls("AGG UPDATE ALIASES")
  end

  def test_s_reg_12_4_an_other_name_is_removed_by_its_entry
    @mock.seed(:agg_window_multiple, PP::ALIASES_WINDOW, "T00035AGGPTALS^I00010RIEN#{RS}OLDNAME,ROBIN^1#{RS}#{US}")
    @mock.seed(:agg_update_aliases, DFN.to_s, "I00010RESULT^T01024ERROR^I00010RIEN#{RS}1^^1#{RS}#{US}")

    assert PP.remove_alias(DFN, 1)[:success]
    assert_equal [ DFN.to_s, "D", "1", "" ], calls("AGG UPDATE ALIASES").first[:params]
  end

  def test_removing_an_entry_the_patient_does_not_have_is_refused
    @mock.seed(:agg_window_multiple, PP::ALIASES_WINDOW, "T00035AGGPTALS^I00010RIEN#{RS}OLDNAME,ROBIN^1#{RS}#{US}")

    assert_equal :not_found, PP.remove_alias(DFN, 9)[:error]
    assert_empty calls("AGG UPDATE ALIASES")
  end

  def test_lookups_send_the_file_and_upcased_text
    @mock.seed(:agg_table_lookup, PP::RELATIONSHIP_FILE,
               "T00015IEN^T00030RELATIONSHIP^T00002UB-92_CODE#{RS}22^SPOUSE^01#{RS}#{US}")

    assert_equal [ { ien: 22, name: "SPOUSE" } ], PP.relationships("sp")
    assert_equal [ PP::RELATIONSHIP_FILE, "SP", "" ], calls("AGG WINDOW TABLE LOOKUP").first[:params]
  end
  # STATE's look-up names two columns NAME; the state's name is the second column.
  def test_states_read_the_name_by_position
    @mock.seed(:agg_table_lookup, PP::STATE_FILE,
               "T00015IEN^T00030NAME^T00002VA_STATE_CODE^T00030NAME#{RS}48^WASHINGTON^53^#{RS}#{US}")

    assert_equal [ { ien: 48, name: "WASHINGTON" } ], PP.states("wash")
  end
end
