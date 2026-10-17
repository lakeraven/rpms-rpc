# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/registration"

# Tests for RpmsRpc::Registration — patient registration through the IHS AG
# package (rpms-rpc#214): AGG ADD NEW PATIENT / AGG UPDATE PATIENT. The VAFC
# VOA ADD PATIENT + DDR composition is gone: no RPMS context serves VOA
# (rpms-rpc#409).
#
# HRN handling has two modes: :derive_from_dfn (default greenfield, HRN := DFN)
# and :clerk_supplied (legacy passthrough). NO client-side HRN uniqueness in
# either mode. All data below is synthetic (DEMOPATIENT names, 900-series
# pseudo-SSNs).
class RegistrationTest < Minitest::Test
  Reg = RpmsRpc::Registration
  Agg = RpmsRpc::Agg

  ATTRS = {
    name: "DEMOPATIENT,UNA",
    dob: Date.new(1990, 1, 2),
    sex: "F",
    ssn: "900010001",
    hrn: "100001",
    # AG window values: pointer IENs for tribe (#9999999.03) and
    # classification (#9999999.25), the set code for eligibility; free-text
    # community has no AG parameter and is named in unfiled:.
    tribe: "123",
    classification: "13",
    eligibility_status: "I",
    community: "EXAMPLE COMMUNITY"
  }.freeze

  def setup
    @mock = RpmsRpc.mock!
    Reg.hrn_mode = Reg::HRN_MODE_DERIVE
    header = "I00010DFN^T00030PATIENT_NAME^T00030HRN^T00009SSN^D00030DOB^D00030DOD^T00003SENS_FLAG^T01024ALIAS^T00001INACTIVE"
    [ [ "UNA", "", "" ], [ "UNA MAE", "", "" ], [ "UNA", "MAE", "JR" ] ].each do |first, middle, suffix|
      query = "AGGPTLNM=DEMOPATIENT\x1cAGGPTFNM=#{first}\x1cAGGPTMNM=#{middle}\x1cAGGPTSFX=#{suffix}\x1cAGGPTDOB=01/02/1990"
      @mock.seed_raw_lines(:patient_lookup_agg, query, [ header ])
    end
  end

  def teardown
    Reg.hrn_mode = Reg::HRN_MODE_DERIVE
    RpmsRpc.reset!
  end

  # Agg.available? probes CIANBRPC CANRUN "AGG ADD NEW PATIENT". Registration
  # no longer asks; a test seeds "0" to show it does not fall back.
  def seed_agg_canrun(answer)
    @mock.seed_scalar(:agg_canrun, "AGG ADD NEW PATIENT", answer)
  end

  def filer_calls
    @mock.received_calls.select { |c| c[:rpc] == "DDR FILER" }
  end

  # -- delegation seeding helpers --------------------------------------------

  def seed_agg_add(dfn: "9", result: "1", message: "")
    reply = "I00010RESULT^T00080MESSAGE^I00010DFN\x1e#{result}^#{message}^#{dfn}\x1e\x1f"
    @mock.seed(:agg_add_patient, Agg::NEW_PATIENT_WINDOW, reply)
  end

  def seed_agg_update(result: "1", error: "")
    reply = "I00010RESULT^T01024ERROR^T01024OTHER_PARMS\x1e#{result}^#{error}^\x1e\x1f"
    @mock.seed(:agg_update_patient, Agg::DEFAULT_WINDOW, reply)
  end

  def agg_calls(rpc)
    @mock.received_calls.select { |c| c[:rpc] == rpc }
  end

  # ==========================================================================
  # Registration goes through AG, and only AG (rpms-rpc#409)
  # ==========================================================================

  def test_register_creates_through_agg_and_files_the_hrn
    seed_agg_add(dfn: "9")
    seed_agg_update

    result = Reg.register(ATTRS)

    assert result[:success]
    assert_equal 9, result[:dfn]
    assert result[:created]
    assert_equal 1, agg_calls("AGG ADD NEW PATIENT").length, "must call the AGG create RPC"
    assert_empty filer_calls, "registration files nothing through DDR"
  end

  # The AGG* RPCs are registered to AGGRPC alone (rpms-rpc#225), so the writes
  # bind it.
  def test_register_runs_the_agg_writes_under_the_agg_context
    seed_agg_add(dfn: "9")
    seed_agg_update

    Reg.register(ATTRS)

    calls = agg_calls("AGG ADD NEW PATIENT") + agg_calls("AGG UPDATE PATIENT")
    refute_empty calls
    calls.each { |c| assert_equal "AGGRPC", c[:context] }
  end

  # The old fallback sent VAFC VOA ADD PATIENT when CANRUN said no. No RPMS
  # context serves that RPC, so there is nothing to fall back to: register
  # neither asks nor composes.
  def test_register_does_not_fall_back_to_vafc_voa_add_patient
    seed_agg_canrun("0")
    seed_agg_add(dfn: "9")
    seed_agg_update

    Reg.register(ATTRS)

    sent = @mock.received_calls.map { |c| c[:rpc] }
    refute_includes sent, "VAFC VOA ADD PATIENT"
    refute_includes sent, "CIANBRPC CANRUN"
    assert_includes sent, "AGG ADD NEW PATIENT"
  end

  def test_register_returns_nil_when_broker_gives_no_response
    # Lookup answered no candidates; the add itself gives no response.
    assert_nil Reg.register(ATTRS)
  end

  def test_register_splits_the_name_at_the_first_comma_only
    seed_agg_add(dfn: "9")
    seed_agg_update

    Reg.register(ATTRS.merge(name: "DEMOPATIENT,UNA MAE"))

    pairs = agg_calls("AGG ADD NEW PATIENT").first[:params][2].split("\x1c")
    assert_includes pairs, "AGGPTLNM=DEMOPATIENT"
    assert_includes pairs, "AGGPTFNM=UNA MAE"
  end

  def test_register_accepts_name_pieces
    seed_agg_add(dfn: "9")
    seed_agg_update

    Reg.register(ATTRS.merge(name: nil, name_last: "DEMOPATIENT", name_first: "UNA",
                             name_middle: "MAE", name_suffix: "JR"))

    pairs = agg_calls("AGG ADD NEW PATIENT").first[:params][2].split("\x1c")
    assert_includes pairs, "AGGPTMNM=MAE"
    assert_includes pairs, "AGGPTSFX=JR"
  end

  def test_register_rejects_caret_in_name_piece_without_echoing_phi
    err = assert_raises(ArgumentError) { Reg.register(ATTRS.merge(name: "DEMO^PATIENT,UNA")) }

    assert_match(/name/, err.message)
    refute_match(/DEMO\^PATIENT/, err.message, "message must not echo the PHI value")
    assert_empty @mock.received_calls
  end

  def test_delegation_add_frames_demographics_as_parms_without_hrn_in_greenfield
    seed_agg_add(dfn: "9")
    seed_agg_update

    Reg.register(ATTRS)

    add = agg_calls("AGG ADD NEW PATIENT").first
    window, dfn, parms = add[:params]
    assert_equal Agg::NEW_PATIENT_WINDOW, window, "the create goes through the window AG registers through"
    assert_equal "", dfn, "new patient => empty DFN"
    pairs = parms.split("\x1c")
    assert_includes pairs, "AGGPTLNM=DEMOPATIENT"
    assert_includes pairs, "AGGPTFNM=UNA"
    assert_includes pairs, "AGGPTSEX=FEMALE"
    assert_includes pairs, "AGGPTDOB=01/02/1990"
    assert_includes pairs, "AGGPTSSN=900010001"
    assert pairs.none? { |p| p.start_with?("AGGPTHRN=") },
           "greenfield must NOT send a clerk HRN on the create call"
  end

  # rpms-rpc#297: tribe, classification, eligibility and community are
  # parameters of AG's own "New Patient" window, so they ride the create and
  # AG files them. Nothing is filed around AG.
  def test_delegation_sends_the_ihs_values_as_new_patient_window_parameters
    seed_agg_add(dfn: "9")
    seed_agg_update

    result = Reg.register(ATTRS.merge(community: nil, community_ien: "18186", community_since: Date.new(2020, 5, 1)))

    pairs = agg_calls("AGG ADD NEW PATIENT").first[:params][2].split("\x1c")
    assert_includes pairs, "AGGPTTRI=123"
    assert_includes pairs, "AGGPTCLB=13"
    assert_includes pairs, "AGGPTELG=I"
    assert_includes pairs, "AGGPTCOM=18186"
    assert_includes pairs, "AGGPTCDT=05/01/2020"
    assert_empty filer_calls, "delegation files nothing through DDR FILER"
    refute result.key?(:unfiled), "everything given was sent"
  end

  def test_delegation_names_free_text_community_as_unfiled
    seed_agg_add(dfn: "9")
    seed_agg_update

    result = Reg.register(ATTRS)

    assert result[:success]
    assert_equal [ :community ], result[:unfiled],
                 "AG stores community as a pointer and a date moved; free text has no parameter"
    pairs = agg_calls("AGG ADD NEW PATIENT").first[:params][2].split("\x1c")
    assert pairs.none? { |p| p.start_with?("AGGPTCOM=", "AGGPTCDT=") }
    assert_empty filer_calls
  end

  # rpms-rpc#300 AC 4: free text given beside the pointer is still not sent
  # (the window has no free-text community parameter), so it is named.
  def test_delegation_names_free_text_community_as_unfiled_beside_the_pointer
    seed_agg_add(dfn: "9")
    seed_agg_update

    result = Reg.register(ATTRS.merge(community_ien: "18186", community_since: Date.new(2020, 5, 1)))

    assert result[:success]
    assert_equal [ :community ], result[:unfiled]
    pairs = agg_calls("AGG ADD NEW PATIENT").first[:params][2].split("\x1c")
    assert_includes pairs, "AGGPTCOM=18186"
    assert_includes pairs, "AGGPTCDT=05/01/2020"
  end

  def test_delegation_names_extra_fields_as_unfiled
    seed_agg_add(dfn: "9")
    seed_agg_update

    result = Reg.register(ATTRS.merge(community: nil, extra_fields: [ { field: "1110", value: "4/4" } ]))

    assert_equal [ :extra_fields ], result[:unfiled]
    assert_empty filer_calls
  end

  def test_delegation_community_needs_the_pointer_and_the_date_together
    err = assert_raises(ArgumentError) { Reg.register(ATTRS.merge(community_ien: "18186")) }

    assert_match(/community_since/, err.message)
    assert_empty agg_calls("AGG ADD NEW PATIENT"), "nothing is sent"
  end

  # AG's GUI resolves "B" (at birth) to a date before it sends; sent as "B"
  # the create answers success and files no community history. So the gem
  # resolves it, and refuses what is not a date.
  def test_delegation_resolves_at_birth_to_the_date_of_birth
    [ :birth, "B", "b" ].each do |since|
      sent = Reg.send(:agg_add_params, ATTRS.merge(community_ien: "18186", community_since: since))
      assert_equal "01/02/1990", sent["AGGPTCDT"], "#{since.inspect} is the date of birth"
    end
  end

  def test_delegation_refuses_a_date_moved_that_is_not_a_date
    [ "TODAY", "last spring", "1990-01-02" ].each do |since|
      err = assert_raises(ArgumentError) { Reg.register(ATTRS.merge(community_ien: "18186", community_since: since)) }
      assert_match(/community_since/, err.message)
    end
    assert_empty agg_calls("AGG ADD NEW PATIENT"), "nothing is sent"
  end

  def test_delegation_at_birth_needs_a_date_of_birth
    err = assert_raises(ArgumentError) do
      Reg.send(:agg_add_params, ATTRS.merge(dob: nil, community_ien: "18186", community_since: :birth))
    end
    assert_match(/dob/, err.message)
  end

  # Every parameter the create sends must be one the window defines:
  # ADD^AGGPTADD rejects a name that is not in the window's "AC" index
  # (AGGPTADD.m:44-45). The fixture is the window as read from a built image.
  def test_delegation_sends_only_parameters_the_new_patient_window_defines
    window = File.readlines(File.expand_path("../../fixtures/agg/new_patient_window.tsv", __dir__))
                 .reject { |l| l.start_with?("#") }.drop(1).map { |l| l.chomp.split("\t", -1) }
    by_name = window.to_h { |row| [ row[1], row ] }

    sent = Reg.send(:agg_add_params, ATTRS.merge(community_ien: "18186", community_since: "05/01/2020"))
    assert_empty sent.keys - by_name.keys, "every PARMS name is a New Patient window parameter"

    { "AGGPTTRI" => Reg::FIELD_TRIBE, "AGGPTCLB" => Reg::FIELD_CLASSIFICATION,
      "AGGPTELG" => Reg::FIELD_ELIGIBILITY, "AGGPTCOM" => "1117" }.each do |name, field|
      assert_equal field, by_name.fetch(name)[6], "#{name} files #9000001 field #{field}"
    end
    assert_includes by_name.keys, "AGGPTHRN", "clerk-mode HRN rides the same window"
  end

  def test_delegation_greenfield_files_hrn_equal_to_dfn_via_update
    seed_agg_add(dfn: "9")
    seed_agg_update

    Reg.register(ATTRS)

    upd = agg_calls("AGG UPDATE PATIENT").first
    refute_nil upd, "greenfield HRN := DFN is filed through the AGG update path"
    _window, dfn, parms = upd[:params]
    assert_equal "9", dfn
    assert_equal "AGGPTHRN=9", parms, "HRN must equal the server-assigned DFN"
  end

  def test_delegation_clerk_mode_sends_supplied_hrn_on_create_and_skips_update
    Reg.hrn_mode = Reg::HRN_MODE_CLERK
    seed_agg_add(dfn: "9")

    result = Reg.register(ATTRS)

    assert result[:success]
    add = agg_calls("AGG ADD NEW PATIENT").first
    assert_includes add[:params][2].split("\x1c"), "AGGPTHRN=100001"
    assert_empty agg_calls("AGG UPDATE PATIENT"),
                 "clerk-supplied HRN rides the create call — no HRN:=DFN update"
  end

  def test_delegation_surfaces_agg_rejection
    seed_agg_add(result: "-1", message: "MISSING MANDATORY FIELD", dfn: "")

    result = Reg.register(ATTRS)

    refute result[:success]
    assert_equal :agg_rejected, result[:error]
    assert_match(/MANDATORY/, result[:message])
    assert_empty agg_calls("AGG UPDATE PATIENT"), "no HRN update after a failed create"
  end

  def test_delegation_hrn_update_failure_surfaces_with_dfn
    seed_agg_add(dfn: "9")
    seed_agg_update(result: "-1", error: "HRN FIELD REJECTED")

    result = Reg.register(ATTRS)

    refute result[:success]
    assert_equal :hrn_file_failed, result[:error]
    assert_equal 9, result[:dfn], "the patient was created; surface the DFN for retry"
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
    forms = { date: "D", sex: "C", choice: "C", pointer: "T", text: "X", ssn: "X", date_moved: "X" }
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
    rpcs = @mock.received_calls.map { |c| c[:rpc] }
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
end
