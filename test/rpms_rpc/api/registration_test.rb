# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/ddr_fileman"

# Tests for RpmsRpc::Registration's update, record and pick lists through the
# IHS AG package (rpms-rpc#381): AGG UPDATE PATIENT per window, under AG's
# lock. The create path is in registration_create_test.rb. All data below is
# synthetic (DEMOPATIENT names, 900-series pseudo-SSNs).
class RegistrationTest < Minitest::Test
  Reg = RpmsRpc::Registration
  Agg = RpmsRpc::Agg

  def setup
    @mock = RpmsRpc.mock!
    Reg.hrn_mode = Reg::HRN_MODE_DERIVE
    # AG's field checks answer "valid" unless a test says otherwise.
    [ Agg::NEW_PATIENT_WINDOW, "Personal Detail", "Address", "Aliases" ].each do |window|
      seed_validation("1^^^^^\x1e", window: window)
    end
  end

  def teardown
    Reg.hrn_mode = Reg::HRN_MODE_DERIVE
    RpmsRpc.reset!
  end

  # AGG WINDOW DATA VALIDATION's reply, as captured live (header, then a row).
  def seed_validation(row, window: Agg::NEW_PATIENT_WINDOW)
    header = "5\x00I00010RESULT^T00100MSG^T00001HANDLER^I00010IEN^T00008CODE^T00100REVALIDATE\x1e"
    @mock.seed(:agg_window_validation, window, header + row.to_s)
  end

  def agg_calls(rpc)
    @mock.received_calls.select { |c| c[:rpc] == rpc }
  end

  # ==========================================================================
  # UPDATE — through AG: AGG UPDATE PATIENT per window, under AGG LOCK
  # PATIENT (rpms-rpc#381). The windows are AG's own definitions, extracted
  # from the FOIA AGG WINDOW DEFINITION export (fixture), not written here.
  # ==========================================================================

  WINDOWS_TSV = File.expand_path("../../fixtures/agg/update_patient_windows.tsv", __dir__)
  NEW_PATIENT_TSV = File.expand_path("../../fixtures/agg/new_patient_window.tsv", __dir__)

  def self.read_tsv(path)
    rows = File.readlines(path).reject { |l| l.start_with?("#") }.map { |l| l.chomp.split("\t", -1) }
    header = rows.shift
    rows.map { |row| header.zip(row).to_h }
  end

  # { window name => { parameter => row } }
  UPDATE_WINDOWS = read_tsv(WINDOWS_TSV).group_by { |r| r["window_name"] }
                                       .transform_values { |rs| rs.to_h { |r| [ r["parameter"], r ] } }

  LOCK_OK = "I00010RESULT^T00080MESSAGE\x1e1^\x1e\x1f"

  def seed_lock(dfn: 42, reply: LOCK_OK)
    @mock.seed(:agg_lock_patient, dfn.to_s, reply)
    @mock.seed(:agg_unlock_patient, dfn.to_s, LOCK_OK)
  end

  def seed_window(window, result: "1", error: "")
    @mock.seed(:agg_update_patient, window,
               "I00010RESULT^T01024ERROR^T01024OTHER_PARMS\x1e#{result}^#{error}^\x1e\x1f")
  end

  def update_calls
    agg_calls("AGG UPDATE PATIENT")
  end

  # [window, { NAME => VALUE }] per AGG UPDATE PATIENT call.
  def sent_windows
    update_calls.map do |c|
      window, _dfn, parms = c[:params]
      [ window, parms.split(Agg::PARM_DELIM).to_h { |pair| pair.split("=", 2) } ]
    end
  end

  # The attribute table is AG's: each attribute is a parameter of its
  # window's "AC" index, filing the field it claims, with the type its value
  # form assumes.
  def test_every_update_attribute_is_a_parameter_of_its_ag_window
    forms = { date: "D", sex: "C", choice: "C", pointer: "T", text: "X", ssn: "X", date_moved: "X", name: "X" }
    Reg::UPDATE_ATTRIBUTES.each do |name, attribute|
      window = UPDATE_WINDOWS.fetch(attribute.window)
      row = window.fetch(attribute.parameter) { flunk "#{name}: #{attribute.parameter} is not in #{attribute.window}" }
      assert_equal "AGG UPDATE PATIENT", row["save_rpc"], "#{attribute.window} saves through UPD^AGGPTUPD"
      assert_equal forms.fetch(attribute.form), row["type"], "#{name}: window type"
      next if attribute.field.nil?

      filed = if row["field"] == attribute.field then row["file"]
      elsif row["secondary_field"] == attribute.field then row["secondary_file"]
      end
      assert_equal attribute.file, filed, "#{name}: #{attribute.parameter} files ##{attribute.file} #{attribute.field}"
    end
  end

  def test_the_choice_values_sent_are_ag_choice_names
    sex = UPDATE_WINDOWS.dig(Reg::WINDOW_PERSONAL_DETAIL, "AGGPTSEX", "choices").split(";").map { |c| c.split("=").first }
    assert_equal [ "MALE", "FEMALE" ], sex
    assert_equal [ "FEMALE", "MALE" ], %w[F m].map { |v| Reg.send(:update_value, Reg::UPDATE_ATTRIBUTES[:sex], v, {}) }
  end

  # The zip and date-moved parameters have no field of their own: zip is
  # filed by the window's M code (PTZP^AGGUL2), date moved by COMM^AGGPTADD.
  def test_zip_and_date_moved_are_filed_by_ag_code_not_a_field
    address = UPDATE_WINDOWS.fetch(Reg::WINDOW_ADDRESS)
    assert_equal "Y", address.dig("AGGPTZIP", "filing_code")
    assert_equal [ "", "" ], address.fetch("AGGPTCDT").values_at("field", "secondary_field")
  end

  # The FOIA export is the same layout the built image carries: the
  # parameters the Address window shares with the live-read New Patient
  # window file the same fields.
  def test_the_foia_windows_agree_with_the_live_new_patient_window
    live = self.class.read_tsv(NEW_PATIENT_TSV).to_h { |r| [ r["parameter"], r ] }
    shared = UPDATE_WINDOWS.values.flat_map(&:values).select { |r| live.key?(r["parameter"]) }
    refute_empty shared
    shared.each do |row|
      l = live.fetch(row["parameter"])
      foia = row["file"] == "2" ? [ row["field"], row["secondary_field"] ] : [ row["secondary_field"], row["field"] ]
      assert_equal [ l["field"], l["secondary_field"] ], foia, "#{row['parameter']} files the same field live and in FOIA"
    end
  end

  def test_update_sends_one_agg_update_per_window_under_the_ag_lock
    seed_lock
    [ Reg::WINDOW_PERSONAL_DETAIL, Reg::WINDOW_ADDRESS, Reg::WINDOW_ELIGIBILITY ].each { |w| seed_window(w) }

    result = Reg.update(42, dob: Date.new(1990, 1, 2), phone_home: "406-555-0101", email: "una@example.test",
                            tribe: "123", eligibility_status: "direct only")

    assert_equal({ success: true, dfn: 42 }, result)
    assert_equal [
      [ "Personal Detail", { "AGGPTDOB" => "01/02/1990" } ],
      [ "Address", { "AGGPTHPH" => "406-555-0101", "AGGPTEML" => "una@example.test" } ],
      [ "Eligibility", { "AGGPTTRI" => "123", "AGGPTELG" => "DIRECT ONLY" } ]
    ], sent_windows
    assert(update_calls.all? { |c| c[:params][1] == "42" })
    rpcs = @mock.received_calls.map { |c| c[:rpc] } - [ "AGG WINDOW DATA VALIDATION" ]
    assert_equal "AGG LOCK PATIENT", rpcs.first
    assert_equal "AGG UNLOCK PATIENT", rpcs.last
    assert(@mock.received_calls.all? { |c| c[:context] == Agg::CONTEXT || c[:rpc] !~ /\AAGG/ })
    refute_includes rpcs, "DDR FILER"
  end

  def test_update_sends_only_the_windows_it_touches
    seed_lock
    seed_window(Reg::WINDOW_ADDRESS)

    Reg.update(42, phone_work: "406-555-0199")

    assert_equal [ [ "Address", { "AGGPTWPH" => "406-555-0199" } ] ], sent_windows
  end

  # rpms-ux S-REG-07.1: the tribal standing goes in one Eligibility window call.
  def test_update_sends_quantums_and_enrollment_number_on_the_eligibility_window
    seed_lock
    seed_window(Reg::WINDOW_ELIGIBILITY)

    Reg.update(42, tribe: "532", classification: "2", eligibility_status: "c", blood_quantum: "1/2",
                   tribe_quantum: "1/4", enrollment_number: "ZZ4901")

    assert_equal [ [ "Eligibility", { "AGGPTTRI" => "532", "AGGPTCLB" => "2", "AGGPTELG" => "C", "AGGPTBLQ" => "1/2",
                                      "AGGPTTRQ" => "1/4", "AGGPTTEN" => "ZZ4901" } ] ], sent_windows
  end

  # UPD re-converts AGGPTCDT before every later parameter (AGGPTUPD.m:61);
  # sent last it is converted once, by COMM^AGGPTADD.
  def test_update_sends_the_date_moved_last_in_its_window
    seed_lock
    seed_window(Reg::WINDOW_ADDRESS)

    Reg.update(42, community_since: Date.new(2020, 5, 1), community_ien: "18186", phone_home: "406-555-0101")

    window, params = sent_windows.first
    assert_equal "Address", window
    assert_equal [ "AGGPTCOM", "AGGPTHPH", "AGGPTCDT" ], params.keys
    assert_equal "05/01/2020", params["AGGPTCDT"]
  end

  def test_update_sends_an_empty_value_to_clear
    seed_lock
    seed_window(Reg::WINDOW_ADDRESS)

    Reg.update(42, phone_work: "", email: nil)

    assert_equal [ [ "Address", { "AGGPTWPH" => "" } ] ], sent_windows
  end

  def test_update_refuses_fields_ag_does_not_file_before_sending
    { phone_cell: /\.134/, pager: /\.135/, community: /1118/ }.each do |name, why|
      err = assert_raises(Reg::AttributeNotOfferedError) { Reg.update(42, name => "X") }
      assert_match(/#{name}:/, err.message)
      assert_match why, err.message
      assert_kind_of RpmsRpc::Error, err
    end
    assert_empty @mock.received_calls
  end

  def test_update_refuses_the_removed_field_number_hashes_with_their_migration
    err = assert_raises(Reg::AttributeNotOfferedError) do
      Reg.update(42, patient_fields: { ".131" => "1", ".133" => "a@b", ".134" => "2" }, ihs_fields: { "1118" => "X" })
    end
    assert_match(/#2 \.131: use phone_home:/, err.message)
    assert_match(/#2 \.133: not offered \(AG keeps email on #9000001 1802: use email:\)/, err.message)
    assert_match(/#2 \.134: not offered/, err.message)
    assert_match(/#9000001 1118: not offered/, err.message)
    assert_empty @mock.received_calls
  end

  def test_update_refuses_unknown_attributes_and_bad_values_before_sending
    assert_raises(ArgumentError) { Reg.update(42, nickname: "X") }
    assert_raises(ArgumentError) { Reg.update(42, tribe: "CHEROKEE") }
    assert_raises(ArgumentError) { Reg.update(42, community_ien: "18186") }
    assert_raises(ArgumentError) { Reg.update(42, community_ien: "", community_since: "05/01/2020") }
    assert_empty @mock.received_calls
  end

  def test_update_does_not_edit_when_the_ag_lock_is_held
    seed_lock(reply: "I00010RESULT^T00080MESSAGE\x1e0^This event is locked for editing by DEMO,USER.\x1e\x1f")

    result = Reg.update(42, phone_home: "406-555-0101")

    assert_equal({ success: false, error: :lock_failed, message: "This event is locked for editing by DEMO,USER." }, result)
    assert_empty update_calls
    refute_includes @mock.received_calls.map { |c| c[:rpc] }, "AGG UNLOCK PATIENT"
  end

  def test_update_answers_lock_failed_when_the_lock_does_not_answer
    result = Reg.update(42, phone_home: "406-555-0101")

    assert_equal :lock_failed, result[:error]
    assert_empty update_calls
  end

  def test_update_answers_invalid_dfn_for_a_patient_ag_cannot_lock
    seed_lock(reply: "I00010RESULT^T00080MESSAGE\x1e-1^Invalid Patient selected\x1e\x1f")

    assert_equal :invalid_dfn, Reg.update(42, phone_home: "1")[:error]
  end

  def test_update_stops_at_a_refused_window_names_what_was_filed_and_unlocks
    seed_lock
    seed_window(Reg::WINDOW_PERSONAL_DETAIL)
    seed_window(Reg::WINDOW_ADDRESS, result: "-1", error: "The value is not valid.")

    result = Reg.update(42, sex: "F", phone_home: "X", tribe: "123")

    assert_equal({ success: false, error: :agg_rejected, window: "Address",
                   message: "The value is not valid.", filed_windows: [ "Personal Detail" ] }, result)
    assert_equal [ "Personal Detail", "Address" ], sent_windows.map(&:first)
    assert_equal "AGG UNLOCK PATIENT", @mock.received_calls.last[:rpc]
  end

  def test_update_rejects_invalid_dfn_and_empty_attributes
    assert_equal :invalid_dfn, Reg.update(0, phone_home: "X")[:error]
    assert_equal :no_fields, Reg.update(42)[:error]
    assert_equal :no_fields, Reg.update(42, email: nil)[:error]
    assert_empty @mock.received_calls
  end
  # ==========================================================================
  # Keeping a registered patient current (rpms-ux S-REG-20, S-REG-21)
  # ==========================================================================

  def validation_calls
    agg_calls("AGG WINDOW DATA VALIDATION").map { |c| c[:params] }
  end

  # S-REG-20.1: the Personal Detail parameters AG files for religion, employer
  # and employment status (#9009068.3 entry 1, parameters 20, 17, 18).
  def test_update_files_religion_employer_and_employment_status_through_personal_detail
    seed_lock
    seed_window(Reg::WINDOW_PERSONAL_DETAIL)

    result = Reg.update(42, religion: "1", employer: "1", employment_status: "full-time", marital_status: "2")

    assert_equal({ success: true, dfn: 42 }, result)
    assert_equal [ [ "Personal Detail", { "AGGPTRLG" => "1", "AGGPTEPL" => "1", "AGGEMSTS" => "FULL-TIME", "AGGPTMAR" => "2" } ] ],
                 sent_windows
  end

  # S-REG-20.10: the name is PTNAME, #2 .01, checked first by AG's name rule.
  def test_update_files_a_corrected_name_after_ags_name_check
    seed_lock
    seed_window(Reg::WINDOW_PERSONAL_DETAIL)

    assert Reg.update(42, name: " demopatient,una ")[:success]

    assert_equal [ [ "Personal Detail", { "PTNAME" => "DEMOPATIENT,UNA" } ] ], sent_windows
    assert_equal [ [ "Aliases", "AGGPTALS=DEMOPATIENT,UNA\x1cDFN=42" ] ], validation_calls
  end

  def test_update_refuses_a_name_ag_refuses_and_files_nothing
    seed_validation("-1^Name does not contain a comma^^^^\x1e", window: "Aliases")

    result = Reg.update(42, name: "DEMOPATIENT UNA")

    assert_equal({ success: false, error: :agg_invalid, field: :name, message: "Name does not contain a comma" }, result)
    assert_empty update_calls
    refute_includes @mock.received_calls.map { |c| c[:rpc] }, "AGG LOCK PATIENT"
  end

  # S-REG-20.7: SSN^AGGWVAL with the patient's DFN refuses another patient's number.
  def test_update_refuses_an_ssn_on_another_patient_with_ags_message
    seed_validation("-1^SSN already used by another patient.^^^^\x1e", window: "Personal Detail")

    result = Reg.update(42, ssn: "666-01-0101", phone_home: "406-555-0101")

    assert_equal({ success: false, error: :agg_invalid, field: :ssn, message: "SSN already used by another patient." }, result)
    assert_equal [ [ "Personal Detail", "AGGPTSSN=666010101\x1cDFN=42" ] ], validation_calls
    assert_empty update_calls
  end

  def test_update_checks_dob_and_zip_in_their_windows
    seed_lock
    seed_window(Reg::WINDOW_PERSONAL_DETAIL)
    seed_window(Reg::WINDOW_ADDRESS)

    Reg.update(42, dob: Date.new(1990, 1, 2), zip: "59000", city: "ANYWHERE")

    assert_equal [ [ "Personal Detail", "AGGPTDOB=01/02/1990\x1cDFN=42" ], [ "Address", "AGGPTZIP=59000\x1cDFN=42" ] ],
                 validation_calls
  end

  def test_update_fails_closed_when_a_check_gives_no_answer
    seed_validation("", window: "Address")

    result = Reg.update(42, zip: "59000")

    assert_equal :validation_unavailable, result[:error]
    assert_equal :zip, result[:field]
    assert_empty update_calls
  end

  # UPD would file "@" for an empty value, deleting the field.
  def test_update_refuses_to_clear_name_sex_or_dob_before_sending
    %i[name sex dob].each do |attribute|
      assert_raises(ArgumentError) { Reg.update(42, attribute => "") }
    end
    assert_empty @mock.received_calls
  end

  DISPLAY_PERSONAL = "5\x00T00035AGGPTLNM^T00025AGGPTFNM^T00025AGGPTMNM^T00010AGGPTSFX^T00030PTNAME^T00009AGGPTSSN^" \
                     "T00020AGGNOSSN^D00015AGGPTDOB^T00006AGGPTSEX^T00030AGGPTMAR^T00033AGGPTSSV^T00009AGGPTHRN^" \
                     "T00020AGGPTPBC^T00035AGGPTPBS^T00020AGGPTMPI^T00010AGGAGE^T00060AGGPTEPL^T00030AGGEMSTS^" \
                     "I00010DFN^T00040AGGPTRLG\x1eEMBER^AVERY^^^EMBER,AVERY^666321031^^MAR 15,1997^F\x1cFEMALE^2\x1cMARRIED^" \
                     "Pending Verification^990031^^\x1c^^29 YRS^1\x1cNEW PERSON EMPLOYER^1\x1cFULL-TIME^^1\x1cCATHOLIC\x1e"
  DISPLAY_ADDRESS = "6\x00T00035AGGPTAD1^T00035AGGPTAD2^T00035AGGPTAD3^T00015AGGPTCTY^T00035AGGPTSTE^T00020AGGPTZIP^" \
                    "T01024AGGPTHME^T00040AGGPTCOM^T00015AGGPTCDT^T00020AGGPTHPH^T00020AGGPTWPH^T00060AGGPTOPH^" \
                    "T00050AGGCMCNY\x1e317 DUNEGRASS ST^^^ANYWHERE^27\x1cMONTANA^59000^^\x1c^^406-555-1031^^^\x1e"

  def test_record_reads_ags_personal_detail_and_address_windows
    @mock.seed(:agg_build_window_display, "Personal Detail", DISPLAY_PERSONAL)
    @mock.seed(:agg_build_window_display, "Address", DISPLAY_ADDRESS)

    record = Reg.record(990_031)

    assert_equal "EMBER,AVERY", record[:name]
    assert_equal Date.new(1997, 3, 15), record[:dob]
    assert_equal({ internal: "F", external: "FEMALE" }, record[:sex])
    assert_equal({ internal: "2", external: "MARRIED" }, record[:marital_status])
    assert_equal({ internal: "1", external: "FULL-TIME" }, record[:employment_status])
    assert_equal({ internal: "1", external: "CATHOLIC" }, record[:religion])
    assert_nil record[:birth_state]
    assert_equal "317 DUNEGRASS ST", record[:address_line1]
    assert_equal({ internal: "27", external: "MONTANA" }, record[:state])
    assert_nil record[:community]
  end

  def test_record_is_nil_for_no_patient_or_no_reply
    assert_nil Reg.record(990_031)
    @mock.seed(:agg_build_window_display, "Personal Detail", "7\x00T00030PTNAME\x1e")
    @mock.seed(:agg_build_window_display, "Address", DISPLAY_ADDRESS)
    assert_nil Reg.record(99_999_999)
    assert_nil Reg.record(0)
  end
  # The marital status, religion, state and employer a clerk chooses from:
  # LIST^DIC over each pointed-to file's "B" index, as Tribal lists tribes.
  def test_pick_list_lists_the_pointed_to_file_by_name
    key = RpmsRpc::DdrFileman.lister_param(file: "11", fields: "@;.01", part: "MA", xref: "B", max: "200").to_s
    @mock.seed(:ddr_lister, key, "[Data]\n2^MARRIED")

    assert_equal [ { ien: 2, name: "MARRIED" } ], Reg.pick_list(:marital_status, part: "MA")
    assert_raises(ArgumentError) { Reg.pick_list(:tribe) }
  end
end
