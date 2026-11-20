# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/ddr_fileman"
require_relative "../captured_replies"

# Registration.register's create path through the IHS AG package
# (rpms-rpc#214): AG's field checks, AGG ADD NEW PATIENT, then the HRN. The VAFC
# VOA ADD PATIENT + DDR composition is gone: no RPMS context serves VOA
# (rpms-rpc#409).
#
# Every reply is the build's (test/fixtures/captured_replies/registration-create.yml),
# captured as PROFILE,REG on a throwaway container: each register flow filed its
# own synthetic patient over CIA, with the duplicate lookup on a BMX session
# signed on as the same user. That lookup answers lookup_none here, the build's
# no-match (the header alone, whoever is looked up). Each test that files checks
# the CIA session sent exactly the recorded calls. The duplicate preflight is in
# registration_safety_test.rb and the HRN read-back in
# test/rpms_rpc/registration_hrn_readback_test.rb.
class RegistrationCreateTest < Minitest::Test
  Reg = RpmsRpc::Registration
  Agg = RpmsRpc::Agg
  SLUG = "registration-create"
  DUZ = "207"

  BASE = { sex: "F", tribe: "204", classification: "13", eligibility_status: "I" }.freeze
  # The capture's patients, as tools/captured_replies/registration-create.rb
  # registered them: each born a day after the one before, from 01/02/1904.
  PATIENTS = {
    "greenfield" => BASE.merge(name: "REGDEMO,UNA", ssn: "900621001", community: "EXAMPLE COMMUNITY"),
    "name_comma" => BASE.merge(name: "REGDEMO,COMMA MAE", ssn: "900621002"),
    "name_pieces" => BASE.merge(name_last: "REGDEMO", name_first: "PIECES", name_middle: "MAE", name_suffix: "JR",
                                ssn: "900621003"),
    "ihs_values" => BASE.merge(name: "REGDEMO,IHS", ssn: "900621004", community_ien: "7421",
                               community_since: Date.new(2020, 5, 1)),
    "extra_fields" => BASE.merge(name: "REGDEMO,EXTRA", ssn: "900621005", extra_fields: [ { field: "1110", value: "4/4" } ]),
    "clerk" => BASE.merge(name: "REGDEMO,CLERK", ssn: "900621006", hrn: "100001"),
    "temporary" => BASE.merge(name: "REGDEMO,TEMP", ssn: "900621007", hrn_source: :temporary),
    "given" => BASE.merge(name: "REGDEMO,GIVEN", ssn: "900621008", hrn_source: :given, hrn: "12345"),
    "given_held" => BASE.merge(name: "REGDEMO,HELD", ssn: "900621009", hrn_source: :given, hrn: "12345"),
    "ssn_held" => BASE.merge(name: "REGDEMO,SSNHELD", ssn: "900621001"),
    "reason_r" => BASE.merge(name: "REGDEMO,REASON", no_ssn_reason: "R"),
    "neither" => BASE.merge(name: "REGDEMO,NEITHER")
  }.each_with_index.to_h { |(key, attrs), i| [ key, attrs.merge(dob: Date.new(1904, 1, 2 + i)) ] }.freeze
  ATTRS = PATIENTS.fetch("greenfield")

  # A CIA session that also records the option bound when each RPC went out.
  class Replay < CapturedReplies::ReplayCiaClient
    def call_rpc_raw(rpc_name, *params)
      super.tap { @calls.last[:context] = current_context }
    end
  end

  def teardown
    Reg.hrn_mode = Reg::HRN_MODE_DERIVE
    RpmsRpc.reset!
  end

  # Register attrs with a flow's replies on the CIA session (none when no
  # flow is named) and the build's no-match on the lookup.
  def register(attrs, flow = nil)
    @session = Replay.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {}).signed_on_as(DUZ)
    RpmsRpc.configure { |c| c.client = @session }
    Reg.with_lookup_client(lookup) { Reg.register(attrs) }
  end

  def lookup
    @lookup = CapturedReplies::ReplayBmxClient.new(CapturedReplies.flow_script(SLUG, "lookup_none"))
    @lookup.instance_variable_set(:@authenticated, true)
    @lookup.instance_variable_set(:@duz, DUZ)
    @lookup.instance_variable_set(:@current_context, Agg::CONTEXT)
    @lookup
  end

  def sent = @session.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def agg_calls(rpc) = @session.calls.select { |c| c[:rpc] == rpc }

  def add_pairs = agg_calls("AGG ADD NEW PATIENT").first[:params][2].split("\x1c")

  # ==========================================================================
  # Registration goes through AG, and only AG (rpms-rpc#409)
  # ==========================================================================

  # The old fallback sent VAFC VOA ADD PATIENT when CANRUN said no. No RPMS
  # context serves that RPC, so there is nothing to fall back to: register
  # neither asks nor composes, and files nothing through DDR.
  def test_register_creates_through_agg_and_files_the_hrn
    result = register(ATTRS, "greenfield")

    assert result[:success]
    assert_equal 990_057, result[:dfn]
    assert result[:created]
    assert_equal CapturedReplies.flow_calls(SLUG, "greenfield"), sent
    assert_equal 1, agg_calls("AGG ADD NEW PATIENT").length, "must call the AGG create RPC"
    assert_empty agg_calls("DDR FILER"), "registration files nothing through DDR"
    refute_includes sent.map(&:first), "VAFC VOA ADD PATIENT"
    refute_includes sent.map(&:first), "CIANBRPC CANRUN"
  end

  # The AGG* RPCs are registered to AGGRPC alone (rpms-rpc#225), so the writes
  # bind it.
  def test_register_runs_the_agg_writes_under_the_agg_context
    register(ATTRS, "greenfield")

    calls = agg_calls("AGG ADD NEW PATIENT") + agg_calls("AGG UPDATE PATIENT")
    refute_empty calls
    calls.each { |c| assert_equal "AGGRPC", c[:context] }
  end

  def test_register_splits_the_name_at_the_first_comma_only
    register(PATIENTS["name_comma"], "name_comma")

    assert_equal CapturedReplies.flow_calls(SLUG, "name_comma"), sent
    assert_includes add_pairs, "AGGPTLNM=REGDEMO"
    assert_includes add_pairs, "AGGPTFNM=COMMA MAE"
  end

  def test_register_accepts_name_pieces
    register(PATIENTS["name_pieces"], "name_pieces")

    assert_equal CapturedReplies.flow_calls(SLUG, "name_pieces"), sent
    assert_includes add_pairs, "AGGPTMNM=MAE"
    assert_includes add_pairs, "AGGPTSFX=JR"
  end

  def test_register_rejects_caret_in_name_piece_without_echoing_phi
    err = assert_raises(ArgumentError) { register(ATTRS.merge(name: "REGDEMO^PATIENT,UNA")) }

    assert_match(/name/, err.message)
    refute_match(/REGDEMO\^PATIENT/, err.message, "message must not echo the PHI value")
    assert_empty @session.calls
  end

  # An HRN given in derive mode is not sent: the calls are those of the
  # registration without it.
  def test_delegation_add_frames_demographics_as_parms_without_hrn_in_greenfield
    register(ATTRS.merge(hrn: "100001"), "greenfield")

    assert_equal CapturedReplies.flow_calls(SLUG, "greenfield"), sent

    window, dfn, = agg_calls("AGG ADD NEW PATIENT").first[:params]
    assert_equal Agg::NEW_PATIENT_WINDOW, window, "the create goes through the window AG registers through"
    assert_equal "", dfn, "new patient => empty DFN"
    assert_includes add_pairs, "AGGPTLNM=REGDEMO"
    assert_includes add_pairs, "AGGPTFNM=UNA"
    assert_includes add_pairs, "AGGPTSEX=FEMALE"
    assert_includes add_pairs, "AGGPTDOB=01/02/1904"
    assert_includes add_pairs, "AGGPTSSN=900621001"
    assert add_pairs.none? { |p| p.start_with?("AGGPTHRN=") },
           "greenfield must NOT send a clerk HRN on the create call"
  end

  # rpms-rpc#297: tribe, classification, eligibility and community are
  # parameters of AG's own "New Patient" window, so they ride the create and
  # AG files them. Nothing is filed around AG.
  def test_delegation_sends_the_ihs_values_as_new_patient_window_parameters
    result = register(PATIENTS["ihs_values"], "ihs_values")

    assert result[:success]
    assert_equal CapturedReplies.flow_calls(SLUG, "ihs_values"), sent
    assert_includes add_pairs, "AGGPTTRI=204"
    assert_includes add_pairs, "AGGPTCLB=13"
    assert_includes add_pairs, "AGGPTELG=I"
    assert_includes add_pairs, "AGGPTCOM=7421"
    assert_includes add_pairs, "AGGPTCDT=05/01/2020"
    assert_empty agg_calls("DDR FILER"), "delegation files nothing through DDR FILER"
    refute result.key?(:unfiled), "everything given was sent"
  end

  def test_delegation_names_free_text_community_as_unfiled
    result = register(ATTRS, "greenfield")

    assert result[:success]
    assert_equal [ :community ], result[:unfiled],
                 "AG stores community as a pointer and a date moved; free text has no parameter"
    assert add_pairs.none? { |p| p.start_with?("AGGPTCOM=", "AGGPTCDT=") }
  end

  # rpms-rpc#300 AC 4: free text given beside the pointer is still not sent
  # (the window has no free-text community parameter), so it is named: the
  # calls are exactly those of the same registration without it.
  def test_delegation_names_free_text_community_as_unfiled_beside_the_pointer
    result = register(PATIENTS["ihs_values"].merge(community: "EXAMPLE COMMUNITY"), "ihs_values")

    assert result[:success]
    assert_equal [ :community ], result[:unfiled]
    assert_equal CapturedReplies.flow_calls(SLUG, "ihs_values"), sent
  end

  def test_delegation_names_extra_fields_as_unfiled
    result = register(PATIENTS["extra_fields"], "extra_fields")

    assert_equal [ :extra_fields ], result[:unfiled]
    assert_equal CapturedReplies.flow_calls(SLUG, "extra_fields"), sent
    assert_empty agg_calls("DDR FILER")
  end

  def test_delegation_community_needs_the_pointer_and_the_date_together
    err = assert_raises(ArgumentError) { register(ATTRS.merge(community_ien: "7421")) }

    assert_match(/community_since/, err.message)
    assert_empty @session.calls, "nothing is sent"
  end

  # AG's GUI resolves "B" (at birth) to a date before it sends; sent as "B"
  # the create answers success and files no community history. So the gem
  # resolves it, and refuses what is not a date.
  def test_delegation_resolves_at_birth_to_the_date_of_birth
    [ :birth, "B", "b" ].each do |since|
      sent = Reg.send(:agg_add_params, ATTRS.merge(community_ien: "7421", community_since: since))
      assert_equal "01/02/1904", sent["AGGPTCDT"], "#{since.inspect} is the date of birth"
    end
  end

  def test_delegation_refuses_a_date_moved_that_is_not_a_date
    [ "TODAY", "last spring", "1904-01-02" ].each do |since|
      err = assert_raises(ArgumentError) { register(ATTRS.merge(community_ien: "7421", community_since: since)) }
      assert_match(/community_since/, err.message)
      assert_empty @session.calls, "nothing is sent"
    end
  end

  def test_delegation_at_birth_needs_a_date_of_birth
    err = assert_raises(ArgumentError) do
      Reg.send(:agg_add_params, ATTRS.merge(dob: nil, community_ien: "7421", community_since: :birth))
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

    sent = Reg.send(:agg_add_params, ATTRS.merge(community_ien: "7421", community_since: "05/01/2020"))
    assert_empty sent.keys - by_name.keys, "every PARMS name is a New Patient window parameter"

    { "AGGPTTRI" => Reg::FIELD_TRIBE, "AGGPTCLB" => Reg::FIELD_CLASSIFICATION,
      "AGGPTELG" => Reg::FIELD_ELIGIBILITY, "AGGPTCOM" => "1117" }.each do |name, field|
      assert_equal field, by_name.fetch(name)[6], "#{name} files #9000001 field #{field}"
    end
    assert_includes by_name.keys, "AGGPTHRN", "clerk-mode HRN rides the same window"
  end

  def test_delegation_greenfield_files_hrn_equal_to_dfn_via_update
    register(ATTRS, "greenfield")

    upd = agg_calls("AGG UPDATE PATIENT").first
    refute_nil upd, "greenfield HRN := DFN is filed through the AGG update path"
    _window, dfn, parms = upd[:params]
    assert_equal "990057", dfn
    assert_equal "AGGPTHRN=990057", parms, "HRN must equal the server-assigned DFN"
  end

  def test_delegation_clerk_mode_sends_supplied_hrn_on_create_and_skips_update
    Reg.hrn_mode = Reg::HRN_MODE_CLERK

    result = register(PATIENTS["clerk"], "clerk")

    assert result[:success]
    assert_equal "100001", result[:hrn]
    assert_equal CapturedReplies.flow_calls(SLUG, "clerk"), sent
    assert_includes add_pairs, "AGGPTHRN=100001"
    assert_empty agg_calls("AGG UPDATE PATIENT"),
                 "clerk-supplied HRN rides the create call — no HRN:=DFN update"
  end

  # -- hrn_source: the mini-registration from scheduling (rpms-ux S-REG-05) ---

  def test_s_reg_05_1_a_temporary_hrn_is_filed_after_the_create
    result = register(PATIENTS["temporary"], "temporary")

    assert_equal({ success: true, dfn: 990_063, created: true, hrn: "T00001" }, result)
    assert_equal CapturedReplies.flow_calls(SLUG, "temporary"), sent
    refute add_pairs.any? { |p| p.start_with?("AGGPTHRN=") }, "the create sends no HRN"
    assert_equal [ "990063" ], agg_calls("AGG GET TEMP PAT HRN").first[:params]
    assert_equal "AGGPTHRN=T00001", agg_calls("AGG UPDATE PATIENT").first[:params][2]
  end

  def test_s_reg_05_2_a_given_hrn_is_checked_by_ag_and_rides_the_create
    result = register(PATIENTS["given"], "given")

    assert_equal "12345", result[:hrn]
    assert_equal CapturedReplies.flow_calls(SLUG, "given"), sent
    assert_includes add_pairs, "AGGPTHRN=12345"
    checked = agg_calls("AGG WINDOW DATA VALIDATION").map { |c| c[:params][1] }
    assert_includes checked, "AGGPTHRN=12345\x1cDFN="
    assert_empty agg_calls("AGG UPDATE PATIENT")
  end

  # The capture registered REGDEMO,GIVEN with HRN 12345 first.
  def test_s_reg_05_5_an_hrn_another_patient_holds_is_refused_in_ag_words_and_nothing_is_filed
    result = register(PATIENTS["given_held"], "given_held")

    assert_equal({ success: false, error: :agg_invalid, field: "AGGPTHRN",
                   message: "HRN 12345 is already assigned to patient REGDEMO,GIVEN" }, result)
    assert_equal CapturedReplies.flow_calls(SLUG, "given_held"), sent
    assert_empty agg_calls("AGG ADD NEW PATIENT")
    assert_empty @lookup.calls, "no lookup after AG refuses a field"
  end

  def test_without_an_hrn_the_only_hrn_check_is_the_derived_number_with_its_dfn
    register(ATTRS, "greenfield")

    # No empty HRN is checked before the create (it would $ORDER from the start of
    # the "D" index); the derived number is checked after it, with the new DFN (#610).
    hrn_checks = agg_calls("AGG WINDOW DATA VALIDATION").select { |c| c[:params][1].start_with?("AGGPTHRN") }
    assert_equal [ "AGGPTHRN=990057\x1cDFN=990057" ], hrn_checks.map { |c| c[:params][1] }
  end

  def test_hrn_source_given_needs_an_hrn_and_an_unknown_source_is_refused
    assert_raises(ArgumentError) { register(ATTRS.merge(hrn_source: :given, hrn: "")) }
    assert_raises(ArgumentError) { register(ATTRS.merge(hrn_source: :clerk)) }
    assert_empty @session.calls
  end

  # ==========================================================================
  # AG's own field checks run before anything is filed (#723)
  # ==========================================================================

  # The capture registered REGDEMO,UNA with SSN 900621001 first.
  def test_register_refuses_with_ags_message_before_it_looks_up_or_adds
    result = register(PATIENTS["ssn_held"], "ssn_held")

    assert_equal({ success: false, error: :agg_invalid, field: "AGGPTSSN", message: "SSN already used by another patient." }, result)
    assert_equal CapturedReplies.flow_calls(SLUG, "ssn_held"), sent
    assert_empty agg_calls("AGG ADD NEW PATIENT")
    assert_empty @lookup.calls
  end

  def test_register_checks_each_field_ag_validates_with_its_companions_and_dfn
    register(PATIENTS["reason_r"], "reason_r")

    assert_equal [
      [ Agg::NEW_PATIENT_WINDOW, "AGGPTSSN=\x1cAGGNOSSN=R\x1cDFN=" ],
      [ Agg::NEW_PATIENT_WINDOW, "AGGNOSSN=R\x1cAGGPTSSN=\x1cDFN=" ],
      [ Agg::NEW_PATIENT_WINDOW, "AGGPTDOB=01/12/1904\x1cDFN=" ],
      # after the create: the derived HRN, with the new DFN (#610)
      [ Agg::NEW_PATIENT_WINDOW, "AGGPTHRN=990065\x1cDFN=990065" ]
    ], agg_calls("AGG WINDOW DATA VALIDATION").map { |c| c[:params] }
    assert_equal CapturedReplies.flow_calls(SLUG, "reason_r"), sent
  end

  def test_register_sends_the_reason_for_no_ssn_to_ag
    register(PATIENTS["reason_r"], "reason_r")

    assert_includes add_pairs, "AGGNOSSN=R"
  end

  # With neither an SSN nor a reason, AG's check errors in ISREQ^AGGUL2 and the
  # broker job then hangs on its next AG call (openrpms#1040), so that one check
  # is not sent: the registration is refused with AG's own wording for it.
  def test_register_with_neither_ssn_nor_reason_is_refused_without_sending_that_check
    result = register(PATIENTS["neither"], "neither")

    assert_equal({ success: false, error: :ssn_or_reason_required, field: "AGGNOSSN",
                   message: "Enter a SSN or a Reason for No SSN" }, result)
    assert_equal CapturedReplies.flow_calls(SLUG, "neither"), sent
    checked = agg_calls("AGG WINDOW DATA VALIDATION").map { |c| c[:params][1].split("=").first }
    refute_includes checked, "AGGNOSSN"
    assert_empty agg_calls("AGG ADD NEW PATIENT")
  end
end
