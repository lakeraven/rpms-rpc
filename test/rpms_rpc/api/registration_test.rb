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
  Ddr = RpmsRpc::DdrFileman
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
  # UPDATE — composed edit path (DDR FILER / FILE^DIE under the ^DPT lock;
  # EDIT^VAFCPTED has no ^XWB(8994) registration on any observed target)
  # ==========================================================================

  def seed_update_lock(dfn: 42, ok: true)
    @mock.seed(:ddr_lock_unlock_node, Ddr.lock_param(node: "^DPT(#{dfn})").to_s, ok)
  end

  def test_update_files_both_halves_through_one_edit_pass
    seed_update_lock
    @mock.seed(:ddr_filer, "EDIT", "[Data]")

    result = Reg.update(42,
      patient_fields: { ".111" => "123 EXAMPLE ST" },
      ihs_fields: { "1118" => "EXAMPLE COMMUNITY" })

    assert result[:success]
    assert_equal 42, result[:dfn]
    filer = filer_calls.last
    assert_equal "EDIT", filer[:params][0]
    assert_equal [ "2^.111^42,^123 EXAMPLE ST", "9000001^1118^42,^EXAMPLE COMMUNITY" ],
                 filer[:params][1].values
  end

  def test_update_fails_and_skips_filer_when_dpt_lock_unavailable
    seed_update_lock(ok: false)

    result = Reg.update(42, patient_fields: { ".111" => "123 EXAMPLE ST" })

    refute result[:success]
    assert_equal :lock_failed, result[:error]
    assert_empty filer_calls
  end

  def test_update_surfaces_filer_rejection_and_still_unlocks
    seed_update_lock
    @mock.seed(:ddr_filer, "EDIT",
      "[BEGIN_diERRORS]\n701^1^2^42,^.111^0\nThe value is not valid.\n[END_diERRORS]")

    result = Reg.update(42, patient_fields: { ".111" => "" })

    refute result[:success]
    assert_equal :filer_rejected, result[:error]
    unlock = @mock.received_calls.last
    assert_equal "DDR LOCK/UNLOCK NODE", unlock[:rpc]
    assert_equal Ddr.unlock_param(node: "^DPT(42)"), unlock[:params].first
  end

  def test_update_rejects_invalid_dfn_and_empty_field_set
    assert_equal :invalid_dfn, Reg.update(0, patient_fields: { ".111" => "X" })[:error]
    assert_equal :no_fields, Reg.update(42)[:error]
    assert_empty @mock.received_calls
  end
end
