# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/patient_profile"
require_relative "../captured_replies"

# RpmsRpc::PatientProfile: the emergency contact, next of kin, languages and
# other names, through AG's GUI windows. The replies are the conversations
# PatientProfile had with the pinned build as PROFILE,REG on synthetic seed
# patient DFN 990007 (test/fixtures/captured_replies/patient-profile.yml, spec
# tools/captured_replies/patient-profile.rb), replayed through CiaClient's own
# GLOBAL ARRAY read. Each test checks the gem sent exactly the recorded calls.
# The round trips themselves are test/live/patient_profile_live_test.rb.
class PatientProfileTest < Minitest::Test
  PP = RpmsRpc::PatientProfile
  SLUG = "patient-profile"
  DFN = 990_007
  SPOUSE = 22
  ENGLISH = 144
  SPANISH = 531

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow)
    @flow = flow
    @client = CapturedReplies::ReplayCiaClient.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {})
    RpmsRpc.configure { |cfg| cfg.client = @client }
    @client
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
  def assert_sent_as_recorded = assert_equal(CapturedReplies.flow_calls(SLUG, @flow), sent, @flow)

  # -- contacts ---------------------------------------------------------------

  def test_contacts_reads_both_windows_with_pointers_split
    replay("contacts")

    result = PP.contacts(DFN)

    assert_equal({ name: "DOE,JANE", relationship: { ien: SPOUSE, name: "SPOUSE" }, other_relationship: "",
                   address_line1: "1 MAIN ST", address_line2: "", address_line3: "", city: "", state: nil,
                   zip: "12345", phone: "555-555-0100", phone_work: "" }, result[:emergency])
    assert_equal "DOE,JOHN", result[:next_of_kin][:name]
    assert_nil result[:next_of_kin][:relationship], "an empty pointer is nil, not { ien: 0 }"
    assert_equal "555-555-0102", result[:next_of_kin][:phone_work]
    assert_sent_as_recorded
  end

  def test_contacts_with_none_on_file_are_empty
    replay("contacts_none")

    assert_equal({ emergency: {}, next_of_kin: {} }, PP.contacts(DFN))
  end

  # -- update_contact -----------------------------------------------------------

  def test_s_reg_08_1_a_contact_is_filed_through_the_window_under_the_lock
    replay("emergency")

    result = PP.update_contact(DFN, :emergency, name: "doe,jane ", relationship: SPOUSE, address_line1: "1 MAIN ST",
                                                zip: "12345", phone: "555-555-0100")

    assert_equal({ success: true, dfn: DFN }, result)
    assert_sent_as_recorded
    update = sent.find { |rpc, _| rpc == "AGG UPDATE PATIENT" }
    assert_equal [ PP::EMERGENCY_WINDOW, DFN.to_s,
                   "AGGECNME=DOE,JANE\x1cAGGECREL=22\x1cAGGECAD1=1 MAIN ST\x1cAGGECZIP=12345\x1cAGGECPHN=555-555-0100" ], update.last
    assert_equal [ "AGG LOCK PATIENT", "AGG UPDATE PATIENT", "AGG UNLOCK PATIENT" ], sent.map(&:first).grep(/LOCK|UPDATE/)
  end

  def test_s_reg_08_1_next_of_kin_uses_its_own_window_and_parameters
    replay("next_of_kin")

    assert PP.update_contact(DFN, :next_of_kin, name: "DOE,JOHN", phone_work: "555-555-0102")[:success]
    assert_sent_as_recorded
    assert_equal [ PP::NEXT_OF_KIN_WINDOW, DFN.to_s, "AGGNKNME=DOE,JOHN\x1cAGGNKWPH=555-555-0102" ],
                 sent.find { |rpc, _| rpc == "AGG UPDATE PATIENT" }.last
  end

  # AG's own name check runs before anything is filed, and its message is the answer.
  def test_s_reg_08_3_a_name_ag_refuses_files_nothing_and_carries_ags_message
    replay("emergency_name_refused")

    result = PP.update_contact(DFN, :emergency, name: "DOE, JANE")

    assert_equal({ success: false, error: :invalid, field: :name, message: "No space after the comma" }, result)
    assert_equal [ [ "AGG WINDOW DATA VALIDATION", [ PP::EMERGENCY_WINDOW, "AGGECNME=DOE, JANE\x1cDFN=#{DFN}" ] ] ], sent
  end

  def test_s_reg_08_3_a_name_shorter_than_the_window_allows_is_refused_before_rpms_is_asked
    replay(nil)

    result = PP.update_contact(DFN, :emergency, name: "AB")

    assert_equal :invalid, result[:error]
    assert_equal :name, result[:field]
    assert_empty sent
  end

  def test_s_reg_08_4_other_fields_with_no_name_on_file_are_refused
    replay("emergency_name_required")

    result = PP.update_contact(DFN, :emergency, relationship: SPOUSE, phone: "555-555-0100")

    assert_equal :name_required, result[:error]
    assert_match(/'EMERGENCY CONTACT' name must be specified/, result[:message])
    assert_sent_as_recorded
    refute_includes sent.map(&:first), "AGG UPDATE PATIENT"
  end

  def test_s_reg_08_4_clearing_the_name_while_giving_other_fields_is_refused
    replay(nil)

    result = PP.update_contact(DFN, :next_of_kin, name: "", phone: "555-555-0100")

    assert_equal :name_required, result[:error]
    assert_match(/'NEXT OF KIN' name/, result[:message])
    assert_empty sent
  end

  def test_other_fields_alone_file_when_a_name_is_on_file
    replay("emergency_city")

    assert PP.update_contact(DFN, :emergency, city: "ANYTOWN")[:success]
    assert_sent_as_recorded
  end

  def test_a_zip_ag_refuses_is_refused_with_its_message
    replay("emergency_zip_refused")

    result = PP.update_contact(DFN, :emergency, zip: "ABCDE")

    assert_equal({ success: false, error: :invalid, field: :zip, message: "Enter numbers for zip code." }, result)
    assert_sent_as_recorded
  end

  def test_unknown_fields_are_refused_before_anything_is_sent
    replay(nil)

    assert_raises(ArgumentError) { PP.update_contact(DFN, :emergency, email: "x@example.test") }
    assert_raises(ArgumentError) { PP.update_contact(DFN, :guardian, name: "DOE,JANE") }
    assert_empty sent
  end

  # -- languages ----------------------------------------------------------------

  def test_languages_reads_the_latest_entry_and_its_other_languages
    replay("languages")

    assert_equal({ date: "NOV 20,2026", primary: { ien: ENGLISH, name: "ENGLISH" }, preferred: nil, interpreter: nil,
                   proficiency: "VW", others: [ { ien: SPANISH, name: "SPANISH" } ] }, PP.languages(DFN))
    assert_sent_as_recorded
  end

  def test_s_reg_10_1_languages_file_a_new_entry_then_its_other_languages
    replay("languages_spanish")

    result = PP.record_languages(DFN, primary: SPANISH, interpreter: "Y", preferred: SPANISH, proficiency: "NW",
                                      others: [ ENGLISH ], english_ien: ENGLISH)

    assert_equal({ success: true, dfn: DFN, entry: 2 }, result)
    assert_sent_as_recorded
    assert_equal [ PP::OTHER_PATIENT_WINDOW, DFN.to_s, "AGGLGPRI=531\x1cAGGINTRP=YES\x1cAGGLGPRF=531\x1cAGGLGEPF=NOT WELL" ],
                 sent.find { |rpc, _| rpc == "AGG UPDATE PATIENT" }.last
  end

  # ULNG copies the entry before's other languages (English) into the new
  # entry: English is removed, Spanish added.
  def test_s_reg_10_1_a_copied_other_language_that_is_not_wanted_is_removed
    replay("languages_switch")

    result = PP.record_languages(DFN, primary: ENGLISH, proficiency: "VW", others: [ SPANISH ], english_ien: ENGLISH)

    assert_equal({ success: true, dfn: DFN, entry: 3 }, result)
    assert_sent_as_recorded
    assert_equal [ [ PP::OTHER_LANGUAGES_WINDOW, DFN.to_s, "3", "A", "AGGLGOTH=531" ],
                   [ PP::OTHER_LANGUAGES_WINDOW, DFN.to_s, "3", "D", "AGGLGOTH=144" ] ],
                 sent.select { |rpc, _| rpc == "AGG UPDATE SPECIAL MULTIPLES" }.map(&:last)
  end

  def test_s_reg_10_3_a_primary_language_other_than_english_needs_the_interpreter_answer
    replay(nil)

    result = PP.record_languages(DFN, primary: SPANISH, preferred: SPANISH, english_ien: ENGLISH)

    assert_equal({ success: false, error: :invalid, field: :interpreter,
                   message: "is required when the primary language is not English" }, result)
    assert_empty sent
  end

  def test_s_reg_10_2_english_needs_a_proficiency
    replay(nil)

    assert_equal :proficiency, PP.record_languages(DFN, primary: ENGLISH, english_ien: ENGLISH)[:field]
    assert_equal :proficiency, PP.record_languages(DFN, primary: SPANISH, interpreter: "N", others: [ ENGLISH ],
                                                        english_ien: ENGLISH)[:field]
    assert_empty sent
  end

  # -- other names ----------------------------------------------------------------

  def test_aliases_lists_the_multiple
    replay("aliases")

    assert_equal [ { ien: 1, name: "OLDNAME,ROBIN" } ], PP.aliases(DFN)
    assert_equal [ [ "AGG BUILD WINDOW MULTIPLE", [ PP::ALIASES_WINDOW, ".01", DFN.to_s, "" ] ] ], sent
  end

  def test_s_reg_12_2_an_other_name_is_checked_then_added
    replay("alias_add")

    assert_equal({ success: true, ien: 1 }, PP.add_alias(DFN, "oldname,robin"))
    assert_sent_as_recorded
    assert_equal [ DFN.to_s, "A", "", "AGGPTALS=OLDNAME,ROBIN" ], sent.find { |rpc, _| rpc == "AGG UPDATE ALIASES" }.last
  end

  def test_s_reg_12_3_an_other_name_out_of_format_or_length_is_refused
    replay("alias_refused")

    assert_equal "No space after the comma", PP.add_alias(DFN, "OLD, NAME")[:message]
    assert_equal :invalid, PP.add_alias(DFN, "AB")[:error]
    assert_equal :invalid, PP.add_alias(DFN, "#{'A' * 20},#{'B' * 20}")[:error]
    assert_sent_as_recorded
  end

  def test_s_reg_12_4_an_other_name_is_removed_by_its_entry
    replay("alias_remove")

    assert PP.remove_alias(DFN, 1)[:success]
    assert_sent_as_recorded
    assert_equal [ DFN.to_s, "D", "1", "" ], sent.find { |rpc, _| rpc == "AGG UPDATE ALIASES" }.last
  end

  def test_removing_an_entry_the_patient_does_not_have_is_refused
    replay("alias_remove_missing")

    assert_equal :not_found, PP.remove_alias(DFN, 999)[:error]
    assert_sent_as_recorded
    refute_includes sent.map(&:first), "AGG UPDATE ALIASES"
  end

  def test_lookups_send_the_file_and_upcased_text
    replay("relationships")

    assert_equal [ { ien: 43, name: "SPONSORED DEPENDENT" }, { ien: SPOUSE, name: "SPOUSE" } ], PP.relationships("sp")
    assert_equal [ [ "AGG WINDOW TABLE LOOKUP", [ PP::RELATIONSHIP_FILE, "SP", "" ] ] ], sent
  end

  # STATE's look-up names two columns NAME; the state's name is the second column.
  def test_states_read_the_name_by_position
    replay("states")

    assert_equal [ { ien: 27, name: "MONTANA" } ], PP.states("mont")
  end
end
