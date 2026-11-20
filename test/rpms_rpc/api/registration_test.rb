# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/ddr_fileman"
require_relative "../captured_replies"

# Tests for RpmsRpc::Registration's update, record and pick lists through the
# IHS AG package (rpms-rpc#381): AGG UPDATE PATIENT per window, under AG's
# lock. The create path is in registration_create_test.rb.
#
# Every reply is the build's (test/fixtures/captured_replies/registration-update.yml),
# captured as PROFILE,REG on a fresh throwaway container: record and pick_list
# reads, then each update in turn on seed patient DFN 990031 (EMBER,AVERY), with
# AG's own refusals. Each test that reaches the wire checks the gem sent exactly
# the recorded calls.
class RegistrationTest < Minitest::Test
  Reg = RpmsRpc::Registration
  Agg = RpmsRpc::Agg
  SLUG = "registration-update"
  DFN = 990_031

  # A CIA session that also records the option bound when each RPC went out.
  class Replay < CapturedReplies::ReplayCiaClient
    def call_rpc_raw(rpc_name, *params)
      super.tap { @calls.last[:context] = current_context }
    end
  end

  def setup
    replay
  end

  def teardown
    RpmsRpc.reset!
  end

  # A client with no replies unless a flow is named: a test that reaches the
  # wire without one fails.
  def replay(flow = nil)
    @client = Replay.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {})
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def assert_sent_flow(flow) = assert_equal(CapturedReplies.flow_calls(SLUG, flow), sent)

  def agg_calls(rpc) = @client.calls.select { |c| c[:rpc] == rpc }

  def update_calls = agg_calls("AGG UPDATE PATIENT")

  def validation_calls = agg_calls("AGG WINDOW DATA VALIDATION").map { |c| c[:params] }

  # [window, { NAME => VALUE }] per AGG UPDATE PATIENT call.
  def sent_windows
    update_calls.map do |c|
      window, _dfn, parms = c[:params]
      [ window, parms.split(Agg::PARM_DELIM).to_h { |pair| pair.split("=", 2) } ]
    end
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
    replay("three_windows")

    result = Reg.update(DFN, dob: Date.new(1997, 3, 15), phone_home: "406-555-0101", email: "una@example.test",
                             tribe: "204", eligibility_status: "direct only")

    assert_equal({ success: true, dfn: DFN }, result)
    assert_sent_flow("three_windows")
    assert_equal [
      [ "Personal Detail", { "AGGPTDOB" => "03/15/1997" } ],
      [ "Address", { "AGGPTHPH" => "406-555-0101", "AGGPTEML" => "una@example.test" } ],
      [ "Eligibility", { "AGGPTTRI" => "204", "AGGPTELG" => "DIRECT ONLY" } ]
    ], sent_windows
    assert(update_calls.all? { |c| c[:params][1] == DFN.to_s })
    rpcs = sent.map(&:first) - [ "AGG WINDOW DATA VALIDATION" ]
    assert_equal "AGG LOCK PATIENT", rpcs.first
    assert_equal "AGG UNLOCK PATIENT", rpcs.last
    assert(@client.calls.all? { |c| c[:rpc] == :create_context || c[:context] == Agg::CONTEXT })
    refute_includes rpcs, "DDR FILER"
  end

  def test_update_sends_only_the_windows_it_touches
    replay("one_window")

    Reg.update(DFN, phone_work: "406-555-0199")

    assert_equal [ [ "Address", { "AGGPTWPH" => "406-555-0199" } ] ], sent_windows
    assert_sent_flow("one_window")
  end

  # rpms-ux S-REG-07.1: the tribal standing goes in one Eligibility window call.
  def test_update_sends_quantums_and_enrollment_number_on_the_eligibility_window
    replay("eligibility")

    Reg.update(DFN, tribe: "204", classification: "2", eligibility_status: "c", blood_quantum: "1/2",
                    tribe_quantum: "1/4", enrollment_number: "ZZ4901")

    assert_equal [ [ "Eligibility", { "AGGPTTRI" => "204", "AGGPTCLB" => "2", "AGGPTELG" => "C", "AGGPTBLQ" => "1/2",
                                      "AGGPTTRQ" => "1/4", "AGGPTTEN" => "ZZ4901" } ] ], sent_windows
    assert_sent_flow("eligibility")
  end

  # UPD re-converts AGGPTCDT before every later parameter (AGGPTUPD.m:61);
  # sent last it is converted once, by COMM^AGGPTADD.
  def test_update_sends_the_date_moved_last_in_its_window
    replay("date_moved")

    Reg.update(DFN, community_since: Date.new(2020, 5, 1), community_ien: "7421", phone_home: "406-555-0101")

    window, params = sent_windows.first
    assert_equal "Address", window
    assert_equal [ "AGGPTCOM", "AGGPTHPH", "AGGPTCDT" ], params.keys
    assert_equal "05/01/2020", params["AGGPTCDT"]
    assert_sent_flow("date_moved")
  end

  def test_update_sends_an_empty_value_to_clear
    replay("clear")

    Reg.update(DFN, phone_work: "", email: nil)

    assert_equal [ [ "Address", { "AGGPTWPH" => "" } ] ], sent_windows
    assert_sent_flow("clear")
  end

  def test_update_refuses_fields_ag_does_not_file_before_sending
    { phone_cell: /\.134/, pager: /\.135/, community: /1118/ }.each do |name, why|
      err = assert_raises(Reg::AttributeNotOfferedError) { Reg.update(DFN, name => "X") }
      assert_match(/#{name}:/, err.message)
      assert_match why, err.message
      assert_kind_of RpmsRpc::Error, err
    end
    assert_empty @client.calls
  end

  def test_update_refuses_the_removed_field_number_hashes_with_their_migration
    err = assert_raises(Reg::AttributeNotOfferedError) do
      Reg.update(DFN, patient_fields: { ".131" => "1", ".133" => "a@b", ".134" => "2" }, ihs_fields: { "1118" => "X" })
    end
    assert_match(/#2 \.131: use phone_home:/, err.message)
    assert_match(/#2 \.133: not offered \(AG keeps email on #9000001 1802: use email:\)/, err.message)
    assert_match(/#2 \.134: not offered/, err.message)
    assert_match(/#9000001 1118: not offered/, err.message)
    assert_empty @client.calls
  end

  def test_update_refuses_unknown_attributes_and_bad_values_before_sending
    assert_raises(ArgumentError) { Reg.update(DFN, nickname: "X") }
    assert_raises(ArgumentError) { Reg.update(DFN, tribe: "CHEROKEE") }
    assert_raises(ArgumentError) { Reg.update(DFN, community_ien: "7421") }
    assert_raises(ArgumentError) { Reg.update(DFN, community_ien: "", community_since: "05/01/2020") }
    assert_empty @client.calls
  end

  # The capture held AG's lock on the patient from a second session, signed on
  # as PROFILE,SCHED.
  def test_update_does_not_edit_when_the_ag_lock_is_held
    replay("lock_held")

    result = Reg.update(DFN, phone_home: "406-555-0101")

    assert_equal({ success: false, error: :lock_failed, message: "This event is locked for editing by PROFILE,SCHED." }, result)
    assert_empty update_calls
    refute_includes sent.map(&:first), "AGG UNLOCK PATIENT"
  end

  def test_update_answers_invalid_dfn_for_a_patient_ag_cannot_lock
    replay("no_patient")

    assert_equal :invalid_dfn, Reg.update(99_999_999, phone_home: "1")[:error]
    assert_sent_flow("no_patient")
  end

  def test_update_rejects_invalid_dfn_and_empty_attributes
    assert_equal :invalid_dfn, Reg.update(0, phone_home: "X")[:error]
    assert_equal :no_fields, Reg.update(DFN)[:error]
    assert_equal :no_fields, Reg.update(DFN, email: nil)[:error]
    assert_empty @client.calls
  end

  # ==========================================================================
  # Keeping a registered patient current (rpms-ux S-REG-20, S-REG-21)
  # ==========================================================================

  # S-REG-20.1: the Personal Detail parameters AG files for religion, employer
  # and employment status (#9009068.3 entry 1, parameters 20, 17, 18).
  def test_update_files_religion_employer_and_employment_status_through_personal_detail
    replay("personal_detail")

    result = Reg.update(DFN, religion: "1", employer: "1", employment_status: "full-time", marital_status: "2")

    assert_equal({ success: true, dfn: DFN }, result)
    assert_equal [ [ "Personal Detail", { "AGGPTRLG" => "1", "AGGPTEPL" => "1", "AGGEMSTS" => "FULL-TIME", "AGGPTMAR" => "2" } ] ],
                 sent_windows
    assert_sent_flow("personal_detail")
  end

  # S-REG-20.10: the name is PTNAME, #2 .01, checked first by AG's name rule.
  def test_update_files_a_corrected_name_after_ags_name_check
    replay("name")

    assert Reg.update(DFN, name: " ember,avery ")[:success]

    assert_equal [ [ "Personal Detail", { "PTNAME" => "EMBER,AVERY" } ] ], sent_windows
    assert_equal [ [ "Aliases", "AGGPTALS=EMBER,AVERY\x1cDFN=990031" ] ], validation_calls
    assert_sent_flow("name")
  end

  def test_update_refuses_a_name_ag_refuses_and_files_nothing
    replay("name_refused")

    result = Reg.update(DFN, name: "EMBER AVERY")

    assert_equal({ success: false, error: :agg_invalid, field: :name, message: "Name does not contain a comma" }, result)
    assert_empty update_calls
    refute_includes sent.map(&:first), "AGG LOCK PATIENT"
    assert_sent_flow("name_refused")
  end

  # S-REG-20.7: SSN^AGGWVAL with the patient's DFN refuses another patient's
  # number: 666101009 is seed patient DFN 990009's.
  def test_update_refuses_an_ssn_on_another_patient_with_ags_message
    replay("ssn_held")

    result = Reg.update(DFN, ssn: "666-10-1009", phone_home: "406-555-0101")

    assert_equal({ success: false, error: :agg_invalid, field: :ssn, message: "SSN already used by another patient." }, result)
    assert_equal [ [ "Personal Detail", "AGGPTSSN=666101009\x1cDFN=990031" ] ], validation_calls
    assert_empty update_calls
  end

  def test_update_checks_dob_and_zip_in_their_windows
    replay("dob_zip")

    Reg.update(DFN, dob: Date.new(1997, 3, 15), zip: "59000", city: "ANYWHERE")

    assert_equal [ [ "Personal Detail", "AGGPTDOB=03/15/1997\x1cDFN=990031" ], [ "Address", "AGGPTZIP=59000\x1cDFN=990031" ] ],
                 validation_calls
    assert_sent_flow("dob_zip")
  end

  # UPD would file "@" for an empty value, deleting the field.
  def test_update_refuses_to_clear_name_sex_or_dob_before_sending
    %i[name sex dob].each do |attribute|
      assert_raises(ArgumentError) { Reg.update(DFN, attribute => "") }
    end
    assert_empty @client.calls
  end

  def test_record_reads_ags_personal_detail_and_address_windows
    replay("record")

    record = Reg.record(DFN)

    assert_sent_flow("record")
    assert_equal "EMBER,AVERY", record[:name]
    assert_equal Date.new(1997, 3, 15), record[:dob]
    assert_equal({ internal: "F", external: "FEMALE" }, record[:sex])
    assert_nil record[:marital_status]
    assert_nil record[:religion]
    assert_nil record[:birth_state]
    assert_equal "317 DUNEGRASS ST", record[:address_line1]
    assert_equal({ internal: "27", external: "MONTANA" }, record[:state])
    assert_equal "59000", record[:zip]
    assert_nil record[:community]
  end

  def test_record_is_nil_for_no_patient_or_no_reply
    replay("record_no_patient")
    assert_nil Reg.record(99_999_999)

    replay
    assert_nil Reg.record(0)
    assert_empty @client.calls
  end

  # The marital status, religion, state and employer a clerk chooses from:
  # LIST^DIC over each pointed-to file's "B" index, as Tribal lists tribes.
  def test_pick_list_lists_the_pointed_to_file_by_name
    replay("pick_marital")

    assert_equal [ { ien: 2, name: "MARRIED" } ], Reg.pick_list(:marital_status, part: "MA")
    assert_sent_flow("pick_marital")
    assert_raises(ArgumentError) { Reg.pick_list(:tribe) }
  end
end
